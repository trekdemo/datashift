# Copyright:: (c) Autotelik Media Ltd 2011
# Author ::   Tom Statter
# Date ::     Aug 2010
# License::   MIT
#
#  Details::  Base class for loaders, providing a process hook which populates a model,
#             based on a method map and supplied value from a file - i.e a single column/row's string value.
#             Note that although a single column, the string can be formatted to contain multiple values.
#
#             Tightly coupled with MethodMapper classes (in lib/engine) which contains full details of
#             a file's column and it's correlated AR associations.
#
module DataShift

  require 'datashift/method_mapper'
  require 'datashift/querying'

  class LoaderBase

    include DataShift::Logging
    include DataShift::Populator
    include DataShift::Querying

    attr_reader :headers

    attr_accessor :method_mapper,
                  :load_object_class, :load_object,
                  :current_value, :current_method_detail,
                  :loaded_objects, :failed_objects,
                  :config, :verbose

    def options; @config; end


    # Setup loading
    #
    # Options to drive building the method dictionary for a class, enabling headers to be mapped to operators on that class.
    #
    # find_operators [default = true] : Populate method dictionary with operators and method details
    #
    # Options
    #
    #  :reload           : Force load of the method dictionary for object_class even if already loaded
    #  :instance_methods : Include setter/delegate style instance methods for assignment, as well as AR columns
    #
    def initialize(object_class, find_operators = true, object = nil, options = {})
      @load_object_class = object_class

      # Gather names of all possible 'setter' methods on AR class (instance variables and associations)
      if((find_operators && !MethodDictionary::for?(object_class)) || options[:reload])
        puts "Building Method Dictionary for class #{object_class}"
        DataShift::MethodDictionary.find_operators( @load_object_class, :reload => options[:reload], :instance_methods => options[:instance_methods] )

        # Create dictionary of data on all possible 'setter' methods which can be used to
        # populate or integrate an object of type @load_object_class
        DataShift::MethodDictionary.build_method_details(@load_object_class)
      end

      @method_mapper = DataShift::MethodMapper.new
      @config = options.dup    # clone can cause issues like 'can't modify frozen hash'

      @verbose = @config[:verbose]
      @headers = []

      @default_data_objects ||= {}

      @default_values  = {}
      @override_values = {}

      @prefixes       = {}
      @postfixes      = {}

      # TODO - move to own LoadStats or LoadReport class
      @loaded_objects = []
      @failed_objects = []

      reset(object)
    end


    # Based on filename call appropriate loading function
    # Currently supports :
    #   Excel/Open Office files saved as .xls
    #   CSV files
    #
    # OPTIONS :
    #
    #  [:dummy]         : Perform a dummy run - attempt to load everything but then roll back
    #
    #  strict           : Raise an exception of any headers can't be mapped to an attribute/association
    #  ignore           : List of column headers to ignore when building operator map
    #  mandatory        : List of columns that must be present in headers
    #
    #  force_inclusion  : List of columns that do not map to any operator but should be includeed in processing.
    #                     This provides the opportunity for loaders to provide specific methods to handle these fields
    #                     when no direct operator is available on the model or it's associations
    #
    def perform_load( file_name, options = {} )

      raise DataShift::BadFile, "Cannot load #{file_name} file not found." unless(File.exists?(file_name))

      logger.info("Perform Load Options:\n#{options.inspect}")

      ext = File.extname(file_name)

      if(ext.casecmp('.xls') == 0)
        perform_excel_load(file_name, options)
      elsif(ext.casecmp('.csv') == 0)
        perform_csv_load(file_name, options)
      else
        raise DataShift::UnsupportedFileType, "#{ext} files not supported - Try .csv or OpenOffice/Excel .xls"
      end
    end

    def report
      loaded_objects.compact! if(loaded_objects)

      puts "Loading stage complete - #{loaded_objects.size} rows added."
      puts "There were NO failures." if failed_objects.empty?

      puts "WARNING : Check logs : #{failed_objects.size} rows contained errors and #{failed_objects.size} records NOT created." unless failed_objects.empty?
    end

    # Core API
    #
    # Given a list of free text column names from a file,
    # map all headers to a MethodDetail instance containing details on operator, look ups etc.
    #
    # These are available through @method_mapper.method_details
    #
    # Options:
    #    [:strict]          : Raise an exception of any headers can't be mapped to an attribute/association
    #    [:ignore]          : List of column headers to ignore when building operator map
    #    [:mandatory]       : List of columns that must be present in headers
    #
    #    [:force_inclusion] : List of columns that do not map to any operator but should be includeed in processing.
    #
    #       This provides the opportunity for loaders to provide specific methods to handle these fields
    #       when no direct operator is available on the modle or it's associations
    #
    #    [:include_all]     : Include all headers in processing - takes precedence of :force_inclusion
    #
    def populate_method_mapper_from_headers( headers, options = {} )
      @headers = headers

      mandatory = options[:mandatory] || []
      strict = (options[:strict] == true)

      begin
        @method_mapper.map_inbound_headers_to_methods( load_object_class, @headers, options )
      rescue => e
        puts e.inspect, e.backtrace
        logger.error("Failed to map header row to set of database operators : #{e.inspect}")
        raise MappingDefinitionError, "Failed to map header row to set of database operators"
      end

      unless(@method_mapper.missing_methods.empty?)
        puts "WARNING: These headings couldn't be mapped to class #{load_object_class} :\n#{@method_mapper.missing_methods.inspect}"
        raise MappingDefinitionError, "Missing mappings for columns : #{@method_mapper.missing_methods.join(",")}" if(strict)
      end

      unless(mandatory.empty? || @method_mapper.contains_mandatory?(mandatory) )
        @method_mapper.missing_mandatory(mandatory).each { |er| puts "ERROR: Mandatory column missing - expected column '#{er}'" }
        raise MissingMandatoryError, "Mandatory columns missing  - please fix and retry."
      end

      @method_mapper
    end


    # Process any defaults user has specified, for those columns that are not included in
    # the incoming import format
    def process_missing_columns_with_defaults()
      inbound_ops = @method_mapper.operator_names
      @default_values.each do |dn, dv|
        assignment(dn, @load_object, dv) unless(inbound_ops.include?(dn))
      end
    end

    # Core API - Given a single free text column name from a file, search method mapper for
    # associated operator on base object class.
    #
    # If suitable association found, process row data and then assign to current load_object
    def find_and_process(column_name, data)

      puts "WARNING: MethodDictionary empty for class #{load_object_class}" unless(MethodDictionary.for?(load_object_class))

      method_detail = MethodDictionary.find_method_detail( load_object_class, column_name )

      if(method_detail)
        prepare_data(method_detail, data)
        process()
      else
        puts "No matching method found for column #{column_name}"
        @load_object.errors.add(:base, "No matching method found for column #{column_name}")
      end
    end


    # Default values and over rides can be provided in YAML config file.
    #
    # Any Config under key 'LoaderBase' is merged over existing options - taking precedence.
    #
    # Any Config under a key equal to the full name of the Loader class (e.g DataShift::SpreeHelper::ImageLoader)
    # is merged over existing options - taking precedence.
    #
    #  Format :
    #
    #    LoaderClass:
    #     option: value
    #
    #    Load Class:    (e.g Spree:Product)
    #     datashift_defaults:
    #       value_as_string: "Default Project Value"
    #       category: reference:category_002
    #
    #     datashift_overrides:
    #       value_as_double: 99.23546
    #
    def configure_from( yaml_file )

      data = YAML::load( File.open(yaml_file) )

      # TODO - MOVE DEFAULTS TO OWN MODULE
      # decorate the loading class with the defaults/ove rides to manage itself
      #   IDEAS .....
      #
      #unless(@default_data_objects[load_object_class])
      #
      #   @default_data_objects[load_object_class] = load_object_class.new

      #  default_data_object = @default_data_objects[load_object_class]


      # default_data_object.instance_eval do
      #  def datashift_defaults=(hash)
      #   @datashift_defaults = hash
      #  end
      #  def datashift_defaults
      #    @datashift_defaults
      #  end
      #end unless load_object_class.respond_to?(:datashift_defaults)
      #end

      #puts load_object_class.new.to_yaml

      logger.info("Read Datashift loading config: #{data.inspect}")

      if(data[load_object_class.name])

        logger.info("Assigning defaults and over rides from config")

        deflts = data[load_object_class.name]['datashift_defaults']
        @default_values.merge!(deflts) if deflts

        ovrides = data[load_object_class.name]['datashift_overrides']
        @override_values.merge!(ovrides) if ovrides
      end

      if(data['LoaderBase'])
        @config.merge!(data['LoaderBase'])
      end

      if(data[self.class.name])
        @config.merge!(data[self.class.name])
      end

      logger.info("Loader Options : #{@config.inspect}")
    end

    # Set member variables to hold details and value.
    #
    # Check supplied value, validate it, and if required :
    #   set to any provided default value
    #   prepend or append with any provided extensions
    def prepare_data(method_detail, value)

      @current_value = value

      @current_method_detail = method_detail

      operator = method_detail.operator

      override_value(operator)

      if((value.nil? || value.to_s.empty?) && default_value(operator))
        @current_value = default_value(operator)
      end

      @current_value = "#{prefixes(operator)}#{@current_value}" if(prefixes(operator))
      @current_value = "#{@current_value}#{postfixes(operator)}" if(postfixes(operator))

      @current_value
    end

    # Return the find_by operator and the rest of the (row,columns) data
    #   price:0.99
    #
    # Column headings can already contain the operator so possible that row only contains
    #   0.99
    # We leave it to caller to manage any other aspects or problems in 'rest'
    #
    def get_find_operator_and_rest(inbound_data)

      operator, rest = inbound_data.split(Delimiters::name_value_delim)

      #puts "DEBUG inbound_data: #{inbound_data} => #{operator} , #{rest}"

      # Find by operator embedded in row takes precedence over operator in column heading
      if(@current_method_detail.find_by_operator)
        # row contains 0.99 so rest is effectively operator, and operator is in method details
        if(rest.nil?)
          rest = operator
          operator = @current_method_detail.find_by_operator
        end
      end

      #puts "DEBUG: get_find_operator_and_rest: #{operator} => #{rest}"

      return operator, rest
    end

    # Process a value string from a column.
    # Assigning value(s) to correct association on @load_object.
    # Method detail represents a column from a file and it's correlated AR associations.
    # Value string which may contain multiple values for a collection association.
    #
    def process()
      logger.info("Current value to assign : #{@current_value}") #if @config['verboose_logging']

      if(@current_method_detail.operator_for(:has_many))

        if(@current_method_detail.operator_class && @current_value)

          # there are times when we need to save early, for example before assigning to
          # has_and_belongs_to associations which require the load_object has an id for the join table

          save_if_new

          # A single column can contain multiple associations delimited by special char
          # Size:large|Colour:red,green,blue => ['Size:large', 'Colour:red,green,blue']
          columns = @current_value.to_s.split( Delimiters::multi_assoc_delim)

          # Size:large|Colour:red,green,blue   => generates find_by_size( 'large' ) and find_all_by_colour( ['red','green','blue'] )

          columns.each do |col_str|

            find_operator, col_values = get_find_operator_and_rest( col_str )

            raise "Cannot perform DB find by #{find_operator}. Expected format key:value" unless(find_operator && col_values)

            find_by_values = col_values.split(Delimiters::multi_value_delim)

            find_by_values << @current_method_detail.find_by_value if(@current_method_detail.find_by_value)

            if(find_by_values.size > 1)

              @current_value = @current_method_detail.operator_class.send("find_all_by_#{find_operator}", find_by_values )

              unless(find_by_values.size == @current_value.size)
                found = @current_value.collect {|f| f.send(find_operator) }
                @load_object.errors.add( @current_method_detail.operator, "Association with key(s) #{(find_by_values - found).inspect} NOT found")
                puts "WARNING: Association #{@current_method_detail.operator} with key(s) #{(find_by_values - found).inspect} NOT found - Not added."
                next if(@current_value.empty?)
              end

            else

              @current_value = @current_method_detail.operator_class.send("find_by_#{find_operator}", find_by_values )

              unless(@current_value)
                @load_object.errors.add( @current_method_detail.operator, "Association with key #{find_by_values} NOT found")
                puts "WARNING: Association with key #{find_by_values} NOT found - Not added."
                next
              end

            end

            # Lookup Assoc's Model done, now add the found value(s) to load model's collection
            @current_method_detail.assign(@load_object, @current_value)
          end
        end
        # END HAS_MANY
      else
        # Nice n simple straight assignment to a column variable
        #puts "INFO: LOADER BASE processing #{method_detail.name}"
        @current_method_detail.assign(@load_object, @current_value)
      end
    end

    def failure
      @failed_objects << @load_object unless( @load_object.nil? || @load_object.new_record? || @failed_objects.include?(@load_object))
    end

    def save
      return unless( @load_object )

      puts "DEBUG: SAVING #{@load_object.class} : #{@load_object.inspect}" if(@verbose)
      begin
        result = @load_object.save

        @loaded_objects << @load_object unless(@loaded_objects.include?(@load_object))

        return result
      rescue => e
        failure
        puts "Error saving #{@load_object.class} : #{e.inspect}"
        logger.error e.backtrace
        raise "Error in save whilst processing column #{@current_method_detail.name}" if(@config[:strict])
      end
    end

    def self.default_object_for( klass )
      @default_data_objects ||= {}
      @default_data_objects[klass]
    end

    def set_default_value( name, value )
      @default_values[name] = value
    end

    def set_override_value( operator, value )
      @override_values[operator] = value
    end

    def default_value(name)
      @default_values[name]
    end

    def override_value( operator )
      @current_value = @override_values[operator] if(@override_values[operator])
    end


    def set_prefix( name, value )
      @prefixes[name] = value
    end

    def prefixes(name)
      @prefixes[name]
    end

    def set_postfix( name, value )
      @postfixes[name] = value
    end

    def postfixes(name)
      @postfixes[name]
    end


    # Reset the loader, including database object to be populated, and load counts
    #
    def reset(object = nil)
      @load_object = object || new_load_object
      @loaded_objects, @failed_objects = [],[]
      @current_value = nil
    end


    def new_load_object
      @load_object = @load_object_class.new
      @load_object
    end

    def abort_on_failure?
      @config[:abort_on_failure] == 'true'
    end

    def loaded_count
      @loaded_objects.size
    end

    def failed_count
      @failed_objects.size
    end


    # Check whether headers contains supplied list
    def headers_contain_mandatory?( mandatory_list )
      [ [*mandatory_list] - @headers].flatten.empty?
    end


    # Check whether headers contains supplied list
    def missing_mandatory_headers( mandatory_list )
      [ [*mandatory_list] - @headers].flatten
    end

    def find_or_new( klass, condition_hash = {} )
      @records[klass] = klass.find(:all, :conditions => condition_hash)
      if @records[klass].any?
        return @records[klass].first
      else
        return klass.new
      end
    end

    protected

    # Take current column data and split into each association
    # Supported Syntax :
    #  assoc_find_name:value | assoc2_find_name:value | etc
    def get_each_assoc
      current_value.to_s.split( Delimiters::multi_assoc_delim )
    end

    private

    def save_if_new
      #puts "SAVE", load_object.inspect
      save if(load_object.valid? && load_object.new_record?)
    end

  end

end
