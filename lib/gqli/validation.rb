# frozen_string_literal: true

module GQLi
  # Validations
  class Validation
    STRING_SCALAR_TYPES = %w[
      String
      ID
      ISO8601DateTime
      ISO8601Date
    ].freeze

    KNOWN_TYPES = STRING_SCALAR_TYPES + %w[
      Int
      Float
      Boolean
      Hash
    ].freeze

    KNOWN_KINDS = %w[INPUT_OBJECT ENUM].freeze

    attr_reader :schema, :root, :errors, :type_name

    def initialize(schema, root)
      @schema = schema
      @root = root
      @errors = []
      @type_name = root.class.name.split('::').last.downcase

      validate
    end

    # Returns wether the query is valid or not
    def valid?
      errors.empty?
    end

    protected

    def validate
      @errors = []

      validate_type(type_name)
    end

    private

    def validate_type(type)
      root_type_name = schema.send("#{type_name}_type").fetch('name')
      root_type = types.find { |t| t.name.casecmp(root_type_name).zero? }
      fail 'Root type not found for #{type}' if root_type.nil?
      root.__nodes.each do |node|
        begin
          validate_node(root_type, node)
        rescue StandardError => e
          errors << e
        end
      end

      valid?
    end

    def remove_alias(name)
      return name unless name.include?(':')

      name.split(':')[1].strip
    end

    def types
      schema.types
    end

    def validate_node(parent_type, node)
      validate_directives(node)

      return valid_match_node?(parent_type, node) if node.__name.start_with?('... on')

      node_name = remove_alias(node.__name)

      node_type = parent_type.fetch('fields', []).find { |f| f.name == node_name }
      fail "Node type not found for '#{node_name}'" if node_type.nil?

      validate_params(node_type, node)

      resolved_node_type = type_for(node_type)
      fail "Node type not found for '#{node_name}'" if resolved_node_type.nil?

      validate_nesting_node(resolved_node_type, node)

      node.__nodes.each { |n| validate_node(resolved_node_type, n) }
    end

    def valid_match_node?(parent_type, node)
      return if parent_type.fetch('possibleTypes', []).find { |t| t.name == node.__name.gsub('... on ', '') }
      fail "Match type '#{node.__name.gsub('... on ', '')}' invalid"
    end

    def validate_directives(node)
      return unless node.__params.size >= 1
      node.__params.first.tap do |k, v|
        break unless k.to_s.start_with?('@')

        fail "Directive unknown '#{k}'" unless %i[@include @skip].include?(k)
        fail "Missing arguments for directive '#{k}'" if v.nil? || !v.is_a?(::Hash) || v.empty?
        v.each do |arg, value|
          begin
            fail "Invalid argument '#{arg}' for directive '#{k}'" if arg.to_s != 'if'
            fail "Invalid value for 'if`, must be a boolean" if value != !!value
          rescue StandardError => e
            errors << e
          end
        end
      end
    end

    def validate_params(node_type, node)
      node.__params.reject { |p, _| p.to_s.start_with?('@') }.each do |param, value|
        begin
          arg = node_type.fetch('args', []).find { |a| a.name == param.to_s }
          fail "Invalid argument '#{param}'" if arg.nil?

          arg_type = type_for(arg)
          fail "Argument type not found for '#{param}'" if arg_type.nil?

          validate_value_for_type(arg_type, value, param)
        rescue StandardError => e
          errors << e
        end
      end
    end

    def validate_nesting_node(node_type, node)
      fail "Invalid object for node '#{node.__name}'" unless valid_object_node?(node_type, node)
    end

    def valid_object_node?(node_type, node)
      return false if %w[OBJECT INTERFACE].include?(node_type.kind) && node.__nodes.empty?
      true
    end

    def valid_array_node?(node_type, node)
      return false if %w[OBJECT INTERFACE].include?(node_type.kind) && node.__nodes.empty?
      true
    end

    def value_type_error(is_type, should_be, for_arg)
      should_be = should_be.kind == 'ENUM' ? 'Enum' : should_be.name
      additional_message = '. Wrap the value with `__enum`.' if should_be == 'Enum'

      fail "Value is '#{is_type}', but should be '#{should_be}' for '#{for_arg}'#{additional_message}"
    end

    def validate_value_for_type(arg_type, value, for_arg)
      return true unless validate_arg_type?(arg_type)
      case value
      when EnumValue
        if arg_type.kind == 'ENUM' && !arg_type.enumValues.map(&:name).include?(value.to_s)
          fail "Invalid value for Enum '#{arg_type.name}' for '#{for_arg}'"
        end
      when ::String
        unless STRING_SCALAR_TYPES.include?(arg_type.name)
          value_type_error('String or ID', arg_type, for_arg)
        end
      when ::Integer
        value_type_error('Integer', arg_type, for_arg) unless arg_type.name == 'Int'
      when ::Float
        value_type_error('Float', arg_type, for_arg) unless arg_type.name == 'Float'
      when ::BigDecimal
        value_type_error('Float', arg_type, for_arg) unless arg_type.name == 'Float'
      when ::Hash
        validate_hash_value(arg_type, value, for_arg)
      when true, false
        value_type_error('Boolean', arg_type, for_arg) unless arg_type.name == 'Boolean'
      when ::Array
        value.each do |v|
          validate_value_for_type(arg_type, v, for_arg)
        end
      else
        value_type_error(value.class.name, arg_type, for_arg)
      end
    end

    def validate_hash_value(arg_type, value, for_arg)
      value_type_error('Object', arg_type.name, for_arg) unless arg_type.kind == 'INPUT_OBJECT'

      type = types.find { |f| f.name == arg_type.name }
      fail "Type not found for '#{arg_type.name}'" if type.nil?

      value.each do |k, v|
        begin
          input_field = type.fetch('inputFields', []).find { |f| f.name == k.to_s }
          fail "Input field definition not found for '#{k}'" if input_field.nil?

          input_field_type = type_for(input_field)
          fail "Input field type not found for '#{k}'" if input_field_type.nil?

          validate_value_for_type(input_field_type, v, k)
        rescue StandardError => e
          errors << e
        end
      end
    end

    def type_for(field_type)
      type = case field_type.type.kind
             when 'NON_NULL'
               non_null_type(field_type.type.ofType)
             when 'LIST'
               non_null_type(field_type.type.ofType)
             when 'OBJECT', 'INTERFACE', 'INPUT_OBJECT', 'ENUM'
               field_type.type
             when 'SCALAR'
               field_type.type
             end

      types.find { |t| t.name == type.name }
    end

    def non_null_type(non_null)
      case non_null.kind
      when 'NON_NULL'
        non_null_type(non_null.ofType)
      when 'LIST'
        non_null_type(non_null.ofType)
      else
        non_null
      end
    end

    def validate_arg_type?(arg_type)
      return true if known_type?(arg_type)
      schema.validate_unknown_types
    end

    def known_type?(arg_type)
      KNOWN_KINDS.include?(arg_type.kind) || KNOWN_TYPES.include?(arg_type.name)
    end
  end
end
