require 'strscan'

##
# Parses a gem.deps.rb.lock file and constructs a LockSet containing the
# dependencies found inside.  If the lock file is missing no LockSet is
# constructed.

class Gem::RequestSet::Lockfile

  ##
  # Raised when a lockfile cannot be parsed

  class ParseError < Gem::Exception

    ##
    # The column where the error was encountered

    attr_reader :column

    ##
    # The line where the error was encountered

    attr_reader :line

    ##
    # The location of the lock file

    attr_reader :path

    ##
    # Raises a ParseError with the given +message+ which was encountered at a
    # +line+ and +column+ while parsing.

    def initialize message, column, line, path
      @line   = line
      @column = column
      @path   = path
      super "#{message} (at line #{line} column #{column})"
    end

  end

  ##
  # The platforms for this Lockfile

  attr_reader :platforms

  ##
  # Creates a new Lockfile for the given +request_set+ and +gem_deps_file+
  # location.

  def initialize request_set, gem_deps_file
    @set           = request_set
    @gem_deps_file = File.expand_path(gem_deps_file)
    @gem_deps_dir  = File.dirname(@gem_deps_file)

    @current_token  = nil
    @line           = 0
    @line_pos       = 0
    @platforms      = []
    @tokens         = []
  end

  def add_DEPENDENCIES out # :nodoc:
    out << "DEPENDENCIES"

    @set.dependencies.sort.map do |dependency|
      source = @requests.find do |req|
        req.name == dependency.name and
          req.spec.class == Gem::Resolver::VendorSpecification
      end

      source_dep = '!' if source

      requirement = dependency.requirement

      out << "  #{dependency.name}#{source_dep}#{requirement.for_lockfile}"
    end

    out << nil
  end

  def add_GEM out # :nodoc:
    out << "GEM"

    source_groups = @spec_groups.values.flatten.group_by do |request|
      request.spec.source.uri
    end

    source_groups.map do |group, requests|
      out << "  remote: #{group}"
      out << "  specs:"

      requests.sort_by { |request| request.name }.each do |request|
        platform = "-#{request.spec.platform}" unless
          Gem::Platform::RUBY == request.spec.platform

        out << "    #{request.name} (#{request.version}#{platform})"

        request.full_spec.dependencies.sort.each do |dependency|
          requirement = dependency.requirement
          out << "      #{dependency.name}#{requirement.for_lockfile}"
        end
      end
    end

    out << nil
  end

  def relative_path_from dest, base # :nodoc:
    dest = File.expand_path(dest)
    base = File.expand_path(base)

    if dest.index(base) == 0
      return dest[base.size+1..-1]
    else
      dest
    end
  end

  def add_PATH out # :nodoc:
    return unless path_requests =
      @spec_groups.delete(Gem::Resolver::VendorSpecification)

    out << "PATH"
    path_requests.each do |request|
      directory = File.expand_path(request.spec.source.uri)

      out << "  remote: #{relative_path_from directory, @gem_deps_dir}"
      out << "  specs:"
      out << "    #{request.name} (#{request.version})"
    end

    out << nil
  end

  def add_PLATFORMS out # :nodoc:
    out << "PLATFORMS"

    platforms = @requests.map { |request| request.spec.platform }.uniq
    platforms.delete Gem::Platform::RUBY if platforms.length > 1

    platforms.each do |platform|
      out << "  #{platform}"
    end

    out << nil
  end

  ##
  # Gets the next token for a Lockfile

  def get expected_types = nil, expected_value = nil # :nodoc:
    @current_token = @tokens.shift

    type, value, column, line = @current_token

    if expected_types and not Array(expected_types).include? type then
      unget

      message = "unexpected token [#{type.inspect}, #{value.inspect}], " +
                "expected #{expected_types.inspect}"

      raise ParseError.new message, column, line, "#{@gem_deps_file}.lock"
    end

    if expected_value and expected_value != value then
      unget

      message = "unexpected token [#{type.inspect}, #{value.inspect}], " +
                "expected [#{expected_types.inspect}, " +
                "#{expected_value.inspect}]"

      raise ParseError.new message, column, line, "#{@gem_deps_file}.lock"
    end

    @current_token
  end

  def parse # :nodoc:
    tokenize

    until @tokens.empty? do
      type, data, column, line = get

      case type
      when :section then
        skip :newline

        case data
        when 'DEPENDENCIES' then
          parse_DEPENDENCIES
        when 'GIT' then
          parse_GIT
        when 'GEM' then
          parse_GEM
        when 'PLATFORMS' then
          parse_PLATFORMS
        else
          type, = get until @tokens.empty? or peek.first == :section
        end
      else
        raise "BUG: unhandled token #{type} (#{data.inspect}) at line #{line} column #{column}"
      end
    end
  end

  def parse_DEPENDENCIES # :nodoc:
    while not @tokens.empty? and :text == peek.first do
      _, name, = get :text

      requirements = []

      case peek[0]
      when :bang then
        get :bang

        git_spec = @set.sets.select { |set|
          Gem::Resolver::GitSet === set
        }.map { |set|
          set.specs[name]
        }.first

        requirements << git_spec.version
      when :l_paren then
        get :l_paren

        loop do
          _, op,      = get :requirement
          _, version, = get :text

          requirements << "#{op} #{version}"

          break unless peek[0] == :comma

          get :comma
        end

        get :r_paren
      end

      @set.gem name, *requirements

      skip :newline
    end
  end

  def parse_GEM # :nodoc:
    get :entry, 'remote'
    _, data, = get :text

    source = Gem::Source.new data

    skip :newline

    get :entry, 'specs'

    skip :newline

    set = Gem::Resolver::LockSet.new source
    last_spec = nil

    while not @tokens.empty? and :text == peek.first do
      _, name, column, = get :text

      case peek[0]
      when :newline then
        last_spec.add_dependency Gem::Dependency.new name if column == 6
      when :l_paren then
        get :l_paren

        type, data, = get [:text, :requirement]

        if type == :text and column == 4 then
          last_spec = set.add name, data, Gem::Platform::RUBY
        else
          dependency =
            if peek[0] == :text then
              _, version, = get :text

              requirements = ["#{data} #{version}"]

              while peek[0] == :comma do
                get :comma
                _, op,      = get :requirement
                _, version, = get :text

                requirements << "#{op} #{version}"
              end

              Gem::Dependency.new name, requirements
            else
              Gem::Dependency.new name
            end

          last_spec.add_dependency dependency
        end

        get :r_paren
      else
        raise "BUG: unknown token #{peek}"
      end

      skip :newline
    end

    @set.sets << set
  end

  def parse_GIT # :nodoc:
    get :entry, 'remote'
    _, repository, = get :text

    skip :newline

    get :entry, 'revision'
    _, revision, = get :text

    skip :newline

    get :entry, 'specs'

    skip :newline

    set = Gem::Resolver::GitSet.new
    last_spec = nil

    while not @tokens.empty? and :text == peek.first do
      _, name, column, = get :text

      case peek[0]
      when :newline then
        last_spec.add_dependency Gem::Dependency.new name if column == 6
      when :l_paren then
        get :l_paren

        type, data, = get [:text, :requirement]

        if type == :text and column == 4 then
          last_spec = set.add_git_spec name, data, repository, revision, true
        else
          dependency =
            if peek[0] == :text then
              _, version, = get :text

              requirements = ["#{data} #{version}"]

              while peek[0] == :comma do
                get :comma
                _, op,      = get :requirement
                _, version, = get :text

                requirements << "#{op} #{version}"
              end

              Gem::Dependency.new name, requirements
            else
              Gem::Dependency.new name
            end

          last_spec.spec.dependencies << dependency
        end

        get :r_paren
      else
        raise "BUG: unknown token #{peek}"
      end

      skip :newline
    end

    @set.sets << set
  end

  def parse_PLATFORMS # :nodoc:
    while not @tokens.empty? and :text == peek.first do
      _, name, = get :text

      @platforms << name

      skip :newline
    end
  end

  ##
  # Peeks at the next token for Lockfile

  def peek # :nodoc:
    @tokens.first
  end

  def skip type # :nodoc:
    get while not @tokens.empty? and peek.first == type
  end

  ##
  # The contents of the lock file.

  def to_s
    @set.resolve

    out = []

    @requests = @set.sorted_requests

    @spec_groups = @requests.group_by do |request|
      request.spec.class
    end

    add_PATH out

    add_GEM out

    add_PLATFORMS out

    add_DEPENDENCIES out

    out.join "\n"
  end

  ##
  # Calculates the column (by byte) and the line of the current token based on
  # +byte_offset+.

  def token_pos byte_offset # :nodoc:
    [byte_offset - @line_pos, @line]
  end

  ##
  # Converts a lock file into an Array of tokens.  If the lock file is missing
  # an empty Array is returned.

  def tokenize # :nodoc:
    @line     = 0
    @line_pos = 0

    @platforms     = []
    @tokens        = []
    @current_token = nil

    lock_file = "#{@gem_deps_file}.lock"

    @input = File.read lock_file
    s      = StringScanner.new @input

    until s.eos? do
      pos = s.pos

      pos = s.pos if leading_whitespace = s.scan(/ +/)

      if s.scan(/[<|=>]{7}/) then
        message = "your #{lock_file} contains merge conflict markers"
        column, line = token_pos pos

        raise ParseError.new message, column, line, lock_file
      end

      @tokens <<
        case
        when s.scan(/\r?\n/) then
          token = [:newline, nil, *token_pos(pos)]
          @line_pos = s.pos
          @line += 1
          token
        when s.scan(/[A-Z]+/) then
          if leading_whitespace then
            text = s.matched
            text += s.scan(/[^\s)]*/).to_s # in case of no match
            [:text, text, *token_pos(pos)]
          else
            [:section, s.matched, *token_pos(pos)]
          end
        when s.scan(/([a-z]+):\s/) then
          s.pos -= 1 # rewind for possible newline
          [:entry, s[1], *token_pos(pos)]
        when s.scan(/\(/) then
          [:l_paren, nil, *token_pos(pos)]
        when s.scan(/\)/) then
          [:r_paren, nil, *token_pos(pos)]
        when s.scan(/<=|>=|=|~>|<|>|!=/) then
          [:requirement, s.matched, *token_pos(pos)]
        when s.scan(/,/) then
          [:comma, nil, *token_pos(pos)]
        when s.scan(/!/) then
          [:bang, nil, *token_pos(pos)]
        when s.scan(/[^\s),!]*/) then
          [:text, s.matched, *token_pos(pos)]
        else
          raise "BUG: can't create token for: #{s.string[s.pos..-1].inspect}"
        end
    end

    @tokens
  rescue Errno::ENOENT
    @tokens
  end

  ##
  # Ungets the last token retrieved by #get

  def unget # :nodoc:
    @tokens.unshift @current_token
  end

  ##
  # Writes the lock file alongside the gem dependencies file

  def write
    open "#{@gem_deps_file}.lock", 'w' do |io|
      io.write to_s
    end
  end

end
