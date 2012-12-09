class ModelMapper

  class << self
    # Helper to deal with string versions of modules/namespaced classes
    # Find and return the base class from a string.
    #
    # e.g "Spree::Property" returns the Spree::Property class
    # Raises exception if no such class found
    #
    def const_get_from_string(const_name)
      const_name_chunks(const_name).inject(Object) do |mod, class_name|
        mod.const_get(class_name)
      end
    end


    # Similar to const_get_from_string except this version
    # returns nil if no such class found
    # Support modules e.g "Spree::Property"
    #
    def class_from_string( const_name )
      ModelMapper.const_get_from_string const_name
    rescue NameError => e
      nil
    end

    private
    def const_name_chunks( const_name )
      const_name.to_s.split('::')
    end
  end
end
