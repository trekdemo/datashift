# Copyright:: (c) Autotelik Media Ltd 2012
# Author ::   Tom Statter
# Date ::     March 2012
# License::   MIT
#
# Details::   This modules provides individual population methods on an AR model.
#
#             Enables users to assign values to AR object, without knowing much about that receiving object.
#
require 'to_b'

module DataShift
  module Populator

    class << self
      def insistent_method_list
        @insistent_method_list ||= [:to_s, :to_i, :to_f, :to_b]
      end

      def insistent_assignment( record, value, operator )
        record.send("#{operator}=", value)
      rescue => e
        Populator::insistent_method_list.each do |f|
          begin
            record.send(op, value.send( f) )
            break
          rescue => e
            puts "DEBUG: insistent_assignment: #{e.inspect}"
            if f == Populator::insistent_method_list.last
              puts  "I'm sorry I have failed to assign [#{value}] to #{operator}"
              raise "I'm sorry I have failed to assign [#{value}] to #{operator}" unless value.nil?
            end
          end
        end
      end
    end

    def assignment( operator, record, value )
      op = operator + '=' unless(operator.include?('='))

      record.send(op, value)
    rescue => e
      Populator::insistent_method_list.each do |f|
        begin
          record.send(op, value.send( f) )
          break
        rescue => e
          #puts "DEBUG: insistent_assignment: #{e.inspect}"
          if f == Populator::insistent_method_list.last
            puts  "I'm sorry I have failed to assign [#{value}] to #{operator}"
            raise "I'm sorry I have failed to assign [#{value}] to #{operator}" unless value.nil?
          end
        end
      end
    end


  end
end
