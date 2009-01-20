module SproutCore

  module BuildTools

    # The ResourceBuilder can combine all of the source files listed in the 
    # passed entry including some basic pre-processing.  The JavaScriptBuilder 
    # extends this to do some JavaScript specific rewriting of URLs, etc. as 
    # well.
    #
    # The ResourceBuilder knows how
    class ResourceBuilder

      attr_reader :bundle, :language, :platform, :filenames

      # Utility method you can call to get the items sorted by load order
      def self.sort_entries_by_load_order(entries, language, bundle, platform)
        filenames = entries.map { |e| e.filename }
        hashed = {}
        entries.each { |e| hashed[e.filename] = e }

        sorted = self.new(filenames, language, bundle, platform).required
        sorted.map { |filename| hashed[filename] }
      end

      def initialize(filenames, language, bundle, platform)
        @bundle = bundle
        @language = language
        @platform = platform
        @filenames = filenames
      end

      # Simply returns the filenames in the order that they were required
      def required
        lines = []; required = []
        while filename = next_filename
          lines, required = _build_one(filename, lines, required, true)
        end
        return lines
      end

      # Actually perform the build.  Returns the compiled resource as a single string.
      def build

        # setup context
        lines = []
        required = []

        # process files
        while filename = next_filename
          lines, required = _build_one(filename, lines, required)
        end

        return join(lines)
      end

      # Join the lines together.  This is one last chance to do some prep of
      # the data (such as minifcation and comment stripping)
      def join(lines)
        # if bundle.minify?
        #   options = {
        #     :preserveComments => false,
        #     :preserveNewlines => false,
        #     :preserveSpaces => true,
        #     :preserveColors => false,
        #     :skipMisc => false
        #   }
        #   SproutCore::CSSPacker.new.compress(lines.join, options)
        # else
          lines.join
        # end
      end

      # Rewrites any inline content such as static urls.  Subclasseses can
      # override this to rewrite any other inline content.
      #
      # The default will rewrite calls to static_url().
      def rewrite_inline_code(line, filename)
        line.gsub(/static_url\([\'\"](.+?)[\'\"]\)/) do | rsrc |
          entry = bundle.find_resource_entry($1, :language => language)
          static_url(entry.nil? ? '' : entry.cacheable_url)
        end
      end

      # Tries to build a single resource.  This may call itself recursively to
      # handle requires.
      #
      # ==== Returns
      # [lines, required] to be passed into the next call
      #
      def _build_one(filename, lines, required, link_only = false)
        return [lines, required] if required.include?(filename)
        required << filename

        entry = bundle.entry_for(filename, :hidden => :include, :language => language, :platform => platform)
        if entry.nil?
          puts "WARNING: Could not find require file: #{filename}"
          return [lines, required]
        end

        file_lines = []
        io = (entry.source_path.nil? || !File.exists?(entry.source_path)) ? [] : File.new(entry.source_path)
        io.each do | line |

          # check for requires.  Only follow a require if the require is in
          # the list of filenames.
          required_file = _require_for(filename, line)
          if required_file && filenames.include?(required_file)
            lines, required = _build_one(required_file, lines, required, link_only)
          end

          file_lines << rewrite_inline_code(line, filename) unless link_only
        end

        # The list of already required filenames is slightly out of order from
        # the actual load order.  Instead, we use the lines array to hold the
        # list of filenames as they are processed.
        if link_only
          lines << filename

        elsif file_lines.size > 0
          
          if entry.ext == "sass"
            file_lines = [ SproutCore::Renderers::Sass.compile(entry, file_lines.join()) ]
          end
          
          lines << "/* Start ----------------------------------------------------- " << filename << "*/\n\n" 
          lines +=  file_lines
          lines << "\n\n/* End ------------------------------------------------------- "  << filename << "*/\n\n"
        end

        return [lines, required]
      end

      # Overridden by subclasses to choose first filename.
      def next_filename; filenames.delete(filenames.first); end

      # Overridden by subclass to handle static_url() in a language specific
      # way.
      def static_url(url); "url('#{url}')"; end

      # check line for required() pattern.  understands JS and CSS.
      def _require_for(filename,line)
        new_file = line.scan(/require\s*\(\s*['"](.*)(\.(js|css|sass))?['"]\s*\)/)
        ret = (new_file.size > 0) ? new_file.first.first : nil
        ret.nil? ? nil : filename_for_require(ret)
      end

      def filename_for_require(ret)
        filenames.include?("#{ret}.css") ? "#{ret}.css" : "#{ret}.sass"
      end
    end

    class JavaScriptResourceBuilder < ResourceBuilder

      # Final processing of file.  Remove comments & minify
      def join(lines)
        if bundle.minify?
          # first suck out any comments that should be retained
          comments = []
          include_line = false
          lines.each do | line |
            is_mark = (line =~ /@license/)
            unless include_line
              if is_mark
                include_line = true
                line= "/*!\n"
              end 
              is_mark = false
            end
            if include_line && is_mark
              include_line = false
              comments << "*/\n"  
            elsif include_line
              comments << line
            end 
          end
          # now minify and prepend any static
          comments.push "\n" unless comments.empty?
          comments.push(lines * '')
          lines = comments
        end
        
        lines.join
      end

      # If the file is a strings.js file, then remove server-side strings...
      def rewrite_inline_code(line, filename)
        if filename == 'strings.js'
          line = line.gsub(/["']@@.*["']\s*?:\s*?["'].*["'],\s*$/,'')
          
        else
          if line.match(/sc_super\(\s*\)/)
            line = line.gsub(/sc_super\(\s*\)/, 'arguments.callee.base.apply(this,arguments)')
          elsif line.match(/sc_super\(.+?\)/)
            puts "\nWARNING: Calling sc_super() with arguments is DEPRECATED. Please use sc_super() only.\n\n"
            line = line.gsub(/sc_super\((.+?)\)/, 'arguments.callee.base.apply(this, \1)')
          end
        end

        super(line, filename)
      end

      def static_url(url); "'#{url}'"; end
      def filename_for_require(ret); "#{ret}.js"; end

      def next_filename
        filenames.delete('strings.js') || filenames.delete('core.js') || filenames.delete('Core.js') || filenames.delete('utils.js') || filenames.delete(filenames.first)
      end

    end

    def self.build_stylesheet(entry, bundle)
      filenames = entry.composite? ? entry.composite_filenames : [entry.filename]
      builder = ResourceBuilder.new(filenames, entry.language, bundle, entry.platform)
      if output = builder.build
        FileUtils.mkdir_p(File.dirname(entry.build_path))
        f = File.open(entry.build_path, 'w')
        f.write(output)
        f.close
      end
    end

    def self.build_javascript(entry, bundle)
      filenames = entry.composite? ? entry.composite_filenames : [entry.filename]
      builder = JavaScriptResourceBuilder.new(filenames, entry.language, bundle, entry.platform)
      if output = builder.build
        FileUtils.mkdir_p(File.dirname(entry.build_path))
        f = File.open(entry.build_path, 'w')
        f.write(output)
        f.close
		if bundle.minify?
			yui_root = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'yui_compressor'))
			jar_path = File.join(yui_root, 'yuicompressor-2.4.2.jar')
			filecompress = "java -jar " + jar_path + " --charset utf-8 " + entry.build_path + " -o " +entry.build_path
			puts 'Compressing with YUI .... '+ entry.build_path
			puts `#{filecompress}`
			if $?.exitstatus != 0
				SC.logger.fatal("!!!!YUI compressor failed, please check that your js code is valid and doesn't contain reserved statements like debugger;")
				SC.logger.fatal("!!!!Failed compressing ... "+ entry.build_path)
				exit(1)
			end
		end
      end
    end

    def self.build_fixture(entry, bundle)
      build_javascript(entry, bundle)
    end
    
    def self.build_debug(entry, bundle)
      build_javascript(entry, bundle)
    end

  end

end
