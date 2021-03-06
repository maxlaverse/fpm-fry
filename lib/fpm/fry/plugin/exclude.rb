require 'fpm/fry/plugin'
module FPM::Fry::Plugin::Exclude

  class Exclude < Struct.new(:matches)

    def call(_, package)
      (package.attributes[:excludes] ||= []).push(*matches)
    end

  end

  def exclude(*matches)
    return if matches.none?
    input_hooks << Exclude.new(matches)
  end

end

