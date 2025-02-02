# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lifeform
  FieldDefinition = Struct.new(:type, :library, :parameters)

  # A form object which stores field definitions and can be rendered as a component
  class Form < Phlex::View # rubocop:todo Metrics/ClassLength
    include CapturingRenderable
    MODEL_PATH_HELPER = :polymorphic_path

    class << self
      def inherited(subclass)
        super
        subclass.library library
      end

      # Helper to point to `I18n.t` method
      def t(...)
        I18n.t(...)
      end

      # @return [Hash<Symbol, FieldDefinition>]
      def fields
        @fields ||= {}
      end

      def subforms
        @subforms ||= {}
      end

      def field(name, type: :text, library: self.library, **parameters)
        parameters[:name] = name.to_sym
        fields[name] = FieldDefinition.new(type, Libraries.const_get(library.to_s.classify), parameters)
      end

      def subform(name, klass, parent_name: nil)
        subforms[name.to_sym] = { class: klass, parent_name: parent_name }
      end

      def library(library_name = nil)
        @library = library_name.to_sym if library_name
        @library ||= :default
      end

      def process_value(key, value)
        return value if key == :if

        case value
        when TrueClass
          key.to_s
        when FalseClass
          nil
        when Symbol, Integer
          value.to_s
        else
          value
        end
      end

      # @param kwargs [Hash]
      def parameters_to_attributes(kwargs)
        attributes = {}
        kwargs.each do |key, value|
          case value
          when Hash
            value.each do |inner_key, inner_value|
              attributes[:"#{key}_#{inner_key}"] = process_value(inner_key, inner_value)
            end
          else
            attributes[key] = process_value(key, value) unless value.nil?
          end
        end

        attributes
      end

      def name_of_model(model)
        return "" if model.nil?

        if model.respond_to?(:to_model)
          model.to_model.model_name.param_key
        else
          # Or just use basic underscore
          model.class.name.underscore.tr("/", "_")
        end
      end
    end

    # @return [Object]
    attr_reader :model

    # @return [String]
    attr_reader :url

    # @return [Class<Libraries::Default>]
    attr_reader :library

    # @return [Hash]
    attr_reader :parameters

    # @return [Boolean]
    attr_reader :emit_form_tag

    # @return [Boolean]
    attr_reader :parent_name

    def initialize( # rubocop:disable Metrics/ParameterLists
      model = nil, url: nil, library: self.class.library, emit_form_tag: true, parent_name: nil, **parameters
    )
      @model, @url, @library_name, @parameters, @emit_form_tag, @parent_name =
        model, url, library, parameters, emit_form_tag, parent_name
      @library = Libraries.const_get(@library_name.to_s.classify)
      @subform_instances = {}

      parameters[:method] ||= model.respond_to?(:persisted?) && model.persisted? ? :patch : :post
      parameters[:accept_charset] ||= "UTF-8"
      verify_method
    end

    def verify_method
      return if %w[get post].include?(parameters[:method].to_s.downcase)

      @method_tag = Class.new(Phlex::View) do # TODO: break this out into a real component
        def initialize(method:)
          @method = method
        end

        def template
          input type: "hidden", name: "_method", value: @method, autocomplete: "off"
        end
      end.new(method: @parameters[:method].to_s.downcase)

      parameters[:method] = :post
    end

    def add_authenticity_token # rubocop:disable Metrics/AbcSize
      if helpers.respond_to?(:token_tag, true) # Rails
        helpers.send(:token_tag, nil, form_options: {
                       action: parameters[:action].to_s,
                       method: parameters[:method].to_s.downcase
                     })
      elsif helpers.respond_to?(:csrf_tag, true) # Roda
        helpers.send(:csrf_tag, action: parameters[:action].to_s, method: parameters[:method].to_s)
      else
        raise Lifeform::Error, "Missing token tag helper. Override `add_authenticity_token' in your Form object"
      end
    end

    def attributes
      @attributes ||= self.class.parameters_to_attributes(parameters)
    end

    def field(name, **field_parameters)
      # @type [FieldDefinition]
      field_definition = self.class.fields[name.to_sym]
      # @type [Class<Libraries::Default>]
      field_library = field_definition.library
      field_library.object_for_field_definition(
        self, field_definition, self.class.parameters_to_attributes(field_parameters)
      )
    end

    def subform(name, model = nil)
      @subform_instances[name.to_sym] ||= self.class.subforms[name.to_sym][:class].new(
        model,
        emit_form_tag: false,
        parent_name: self.class.subforms[name.to_sym][:parent_name] || self.class.name_of_model(self.model)
      )
    end

    def template(&block) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      form_tag = library::FORM_TAG
      parameters[:action] ||= url || (model ? helpers.send(self.class.const_get(:MODEL_PATH_HELPER), model) : nil)

      send(form_tag, **attributes) do
        raw(add_authenticity_token) unless parameters[:method].to_s.downcase == "get"
        raw @method_tag&.() || ""
        block ? yield_content(&block) : auto_render_fields
      end
    end

    def auto_render_fields
      self.class.fields.map { |k, _v| render(field(k)) }
    end
  end
end
