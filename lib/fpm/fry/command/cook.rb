require 'fpm/fry/command'
module FPM; module Fry
  class Command::Cook < Command

    option '--keep', :flag, 'Keep the container after build'
    option '--overwrite', :flag, 'Overwrite package', default: true

    UPDATE_VALUES = ['auto','never','always']
    option '--update',"<#{UPDATE_VALUES.join('|')}>", 'Update image before installing packages ( only apt currently )',attribute_name: 'update', default: 'auto' do |value|
      if !UPDATE_VALUES.include? value
        raise "Unknown value for --update: #{value.inspect}\nPossible values are #{UPDATE_VALUES.join(', ')}"
      else
        value
      end
    end

    parameter 'image', 'Docker image to build from'
    parameter '[recipe]', 'Recipe file to cook', default: 'recipe.rb'

    def initialize(invocation_path, ctx = {}, parent_attribute_values = {})
      @tls = nil
      require 'digest'
      require 'fileutils'
      require 'fpm/fry/with_data'
      require 'fpm/fry/recipe'
      require 'fpm/fry/recipe/builder'
      require 'fpm/fry/detector'
      require 'fpm/fry/docker_file'
      require 'fpm/fry/stream_parser'
      require 'fpm/fry/block_enumerator'
      require 'fpm/fry/build_output_parser'
      require 'fpm/fry/inspector'
      require 'fpm/fry/plugin/config'
      super
    end

    def output_class
      @output_class ||= begin
        logger.debug("Autodetecting package type",flavour: flavour)
        case(flavour)
        when 'debian'
          require 'fpm/package/deb'
          FPM::Package::Deb
        when 'redhat'
          require 'fpm/package/rpm'
          FPM::Package::RPM
        else
          raise "Cannot auto-detect package type."
        end
      end
    end
    attr_writer :output_class

    def builder
      @builder ||= begin
        b = nil
        Inspector.for_image(client, image) do |inspector|
          variables = Detector.detect(inspector)
          logger.debug("Loading recipe",variables: variables, recipe: recipe)
          b = Recipe::Builder.new(variables, logger: ui.logger, inspector: inspector)
          b.load_file( recipe )
        end
        b
      end
    end
    attr_writer :builder

    def flavour
      builder.variables[:flavour]
    end

    def cache
      @cache ||= builder.recipe.source.build_cache(tmpdir)
    end
    attr_writer :cache

    def lint_output_class!

    end

    def lint_recipe_file!
      File.exists?(recipe) || raise(Recipe::NotFound)
    end

    def lint_recipe!
      problems = builder.recipe.lint
      if problems.any?
        problems.each do |p|
          logger.error(p)
        end
        raise
      end
    end

    def image_id
      @image_id ||= begin
        res = client.get(
          expects: [200],
          path: client.url("images/#{image}/json")
        )
        body = JSON.parse(res.body)
        body.fetch('id'){ body.fetch('Id') }
      end
    end
    attr_writer :image_id

    def build_image
      @build_image ||= begin
        sum = Digest::SHA256.hexdigest( image_id + "\0" + cache.cachekey )
        cachetag = "fpm-fry:#{sum[0..30]}"
        res = client.get(
          expects: [200,404],
          path: client.url("images/#{cachetag}/json")
        )
        if res.status == 404
          df = DockerFile::Source.new(builder.variables.merge(image: image_id),cache)
          client.post(
            headers: {
              'Content-Type'=>'application/tar'
            },
            expects: [200],
            path: client.url("build?rm=1&dockerfile=#{DockerFile::NAME}&t=#{cachetag}"),
            request_block: BlockEnumerator.new(df.tar_io)
          )
        else
          # Hack to trigger hints/warnings even when the cache is valid.
          DockerFile::Source.new(builder.variables.merge(image: image_id),cache).send(:file_map)
        end

        df = DockerFile::Build.new(cachetag, builder.variables.dup,builder.recipe, update: update?)
        parser = BuildOutputParser.new(out)
        res = client.post(
          headers: {
            'Content-Type'=>'application/tar'
          },
          expects: [200],
          path: client.url("build?rm=1&dockerfile=#{DockerFile::NAME}"),
          request_block: BlockEnumerator.new(df.tar_io),
          response_block: parser
        )
        if parser.images.none?
          raise "Didn't find a build image in the stream. This usually means that the build script failed."
        end
        image = parser.images.last
        logger.debug("Detected build image", image: image)
        image
      end
    end
    attr_writer :build_image

    def update?
      if flavour == 'debian'
        case(update)
        when 'auto'
          Inspector.for_image(client, image) do |inspector|
            inspector.read('/var/lib/apt/lists') do |file|
              next if file.header.name == 'lists/'
              logger.hint("/var/lib/apt/lists is not empty, you could try to speed up builds with --update=never", documentation: 'https://github.com/xing/fpm-fry/wiki/The-update-parameter')
              break
            end
          end
          return true
        when 'always'
          return true
        when 'never'
          return false
        end
      else
        return false
      end
    end

    def build!
      res = client.post(
         headers: {
          'Content-Type' => 'application/json'
         },
         path: client.url('containers','create'),
         expects: [201],
         body: JSON.generate({"Image" => build_image})
      )

      body = JSON.parse(res.body)
      container = body['Id']
      begin
        client.post(
          headers: {
            'Content-Type' => 'application/json'
          },
          path: client.url('containers',container,'start'),
          expects: [204],
          body: JSON.generate({})
        )

        client.post(
          path: client.url('containers',container,'attach?stderr=1&stdout=1&stream=1'),
          body: '',
          expects: [200],
          middlewares: [
            StreamParser.new(out,err),
            Excon::Middleware::Expects,
            Excon::Middleware::Instrumentor,
            Excon::Middleware::Mock
          ]
        )

        res = client.post(
          path: client.url('containers',container,'wait'),
          expects: [200],
          body: ''
        )
        json = JSON.parse(res.body)
        if json["StatusCode"] != 0
          raise Fry::WithData("Build failed", exit_code: json["StatusCode"])
        end
        return yield container
      ensure
        unless keep?
          client.destroy(container)
        end
      end
    end

    def input_package(container)
      input = FPM::Package::Docker.new(logger: logger, client: client)
      builder.recipe.apply_input(input)
      begin
        input.input(container)
        return yield(input)
      ensure
        input.cleanup_staging
        input.cleanup_build
      end
    end

    def write_output!(output)
      package_file = File.expand_path(output.to_s(nil))
      FileUtils.mkdir_p(File.dirname(package_file))
      tmp_package_file = package_file + '.tmp'
      begin
        FileUtils.rm_rf tmp_package_file
      rescue Errno::ENOENT
      end

      output.output(tmp_package_file)

      if output.config_files.any?
        logger.debug("Found config files for #{output.name}", files: output.config_files)
      else
        logger.debug("No config files for #{output.name}")
      end

      begin
        FileUtils.rm_rf package_file
      rescue Errno::ENOENT
      end
      File.rename tmp_package_file, package_file

      logger.info("Created package", :path => package_file)
    end

    def packages
      dir_map = []
      out_map = {}

      package_map = builder.recipe.packages.map do | package |
        output = output_class.new
        output.instance_variable_set(:@logger,logger)
        package.files.each do | pattern |
          dir_map << [ pattern, output.staging_path ]
        end
        out_map[ output ] = package
      end

      dir_map = Hash[ dir_map.reverse ]

      yield dir_map

      out_map.each do |output, package|
        package.apply_output(output)
        adjust_package_settings(output)
        adjust_config_files(output)
      end

      out_map.each do |output, _|
        write_output!(output)
      end

    ensure

      out_map.each do |output, _|
        output.cleanup_staging
        output.cleanup_build
      end

    end

    def adjust_package_settings( output )
      # FPM ignores the file permissions on rpm packages.
      output.attributes[:rpm_use_file_permissions?] = true
      output.attributes[:rpm_user] = 'root'
      output.attributes[:rpm_group] = 'root'
    end

    def adjust_config_files( output )
      # FPM flags all files in /etc as config files but only for debian :/.
      # Actually this behavior makes sense to me for all packages because it's 
      # the thing I usually want. By setting this attribute at least the 
      # misleading warning goes away.
      output.attributes[:deb_no_default_config_files?] = true
      output.attributes[:deb_auto_config_files?] = false

      return if output.attributes[:fry_config_explicitly_used]

      # Now that we have disabled this for debian we have to reenable if it for 
      # all.
      etc = File.expand_path('etc', output.staging_path)
      if File.exists?( etc )
        # Config plugin wasn't used. Add everything under /etc
        prefix_length = output.staging_path.size + 1
        added = []
        Find.find(etc) do | path |
          next unless File.file? path
          name = path[prefix_length..-1]
          if !output.config_files.include? name
            added << name
            output.config_files << name
          end
        end
        if added.any?
          logger.hint( "#{output.name} contains some config files in /etc. They were automatically added. You can customize this using the \"config\" plugin.",
                      documentation: "https://github.com/xing/fpm-fry/wiki/Plugin-config",
                      files: added)
        end
      end
    end

  public

    def execute
      # force some eager loading
      lint_recipe_file!
      builder
      lint_output_class!
      lint_recipe!
      cache

      image_id
      build_image

      packages do | dir_map |

        build! do |container|
          input_package(container) do |input|
            input.split( container, dir_map )
          end
        end

      end

      return 0
    rescue Recipe::NotFound => e
      logger.error("Recipe not found", recipe: recipe, exception: e)
      return 1
    rescue => e
      logger.error(e)
      return 1
    end

  end

  class Command
    subcommand 'cook', 'Cooks a package', Cook
  end
end ; end
