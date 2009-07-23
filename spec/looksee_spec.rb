require 'spec_helper'

describe Looksee do
  include TemporaryClasses

  describe ".lookup_modules" do
    #
    # Wrapper for the method under test.
    #
    # Filter out modules which are hard to test against, and returns
    # the list of module names.  #inspect strings are used for names
    # of singleton classes, since they have no name.
    #
    def filtered_lookup_modules(object)
      result = Looksee.lookup_modules(object)
      # Singleton classes have no name ('' in <1.9, nil in 1.9+).  Use
      # the inspect string instead.
      names = result.map{|mod| mod.name.to_s.empty? ? mod.inspect : mod.name}
      names.select{|name| deterministic_module_name?(name)}
    end

    #
    # Return true if the given module name is of a module we can test
    # for.
    #
    # This excludes ruby version dependent modules, and modules tossed
    # into the hierarchy by testing frameworks.
    #
    def deterministic_module_name?(name)
      junk_patterns = [
        # pollution from testing libraries
        'Mocha', 'Spec',
        # RSpec adds this under ruby 1.8.6
        'InstanceExecHelper',
        # only in ruby 1.9
        'BasicObject',
        # something pulls this in under ruby 1.9
        'PP',
      ]

      # Singleton classes of junk are junk.
      while name =~ /\A#<Class:(.*)>\z/
        name = $1
      end

      name !~ /\A(#{junk_patterns.join('|')})/
    end

    it "should contain an entry for each module in the object's lookup path" do
      temporary_module :Mod1
      temporary_module :Mod2
      temporary_class :Base
      temporary_class :Derived, Base do
        include Mod1
        include Mod2
      end
      filtered_lookup_modules(Derived.new) == %w'Derived Mod2 Mod1 Base Object Kernel'
    end

    it "contain an entry for the object's singleton class if it exists" do
      object = Object.new
      object.singleton_class

      result = filtered_lookup_modules(object)
      result.shift.should =~ /\A#<Class:\#<Object:0x[\da-f]+>>\z/
      result.should == %w"Object Kernel"
    end

    it "should contain entries for singleton classes of all ancestors for class objects" do
      temporary_class :C
      result = filtered_lookup_modules(C)
      result.should == %w'#<Class:C> #<Class:Object> Class Module Object Kernel'
    end
  end

  describe ".lookup_path" do
    it "should return a LookupPath object" do
      object = Object.new
      lookup_path = Looksee.lookup_path(object)
      lookup_path.should be_a(Looksee::LookupPath)
    end

    it "should return a LookupPath object for the given object" do
      object = Object.new
      Looksee.stubs(:default_lookup_path_options).returns({})
      Looksee::LookupPath.expects(:for).with(object, {})
      lookup_path = Looksee.lookup_path(object)
    end

    it "should allow symbol arguments as shortcuts for true options" do
      object = Object.new
      Looksee.stubs(:default_lookup_path_options).returns({})
      Looksee::LookupPath.expects(:for).with(object, {:public => true, :overridden => true})
      Looksee.lookup_path(object, :public, :overridden)
    end

    it "should merge the default options, with the symbols, and the options hash" do
      object = Object.new
      Looksee.stubs(:default_lookup_path_options).returns({:public => false, :protected => false, :private => false})
      Looksee::LookupPath.expects(:for).with(object, {:public => false, :protected => true, :private => false})
      Looksee.lookup_path(object, :protected, :private, :private => false)
    end
  end

  describe "internal instance methods:" do
    #
    # Remove all methods defined exactly on the given module.  As Ruby's
    # reflection on singleton classes of classes isn't quite adequate,
    # you need to provide a :class_singleton option when such a class is
    # given.
    #
    def remove_methods(mod, opts={})
      names = all_instance_methods(mod)

      # all_instance_methods can't get just the methods on a class
      # singleton class.  Filter out superclass methods here.
      if opts[:class_singleton]
        klass = ObjectSpace.each_object(mod){|klass| break klass}
        names -= all_instance_methods(klass.superclass.singleton_class)
      end

      names.sort_by{|name| name.in?([:remove_method, :send]) ? 1 : 0}.flatten
      names.each do |name|
        mod.send :remove_method, name
      end
    end

    def define_methods(mod, opts)
      mod.module_eval do
        [:public, :protected, :private].each do |visibility|
          Array(opts[visibility]).each do |name|
            define_method(name){}
            send visibility, name
          end
        end
      end
    end

    def all_instance_methods(mod)
      names =
        mod.public_instance_methods(false) +
        mod.protected_instance_methods(false) +
        mod.private_instance_methods(false)
      names.map{|name| name.to_sym}  # they're strings in ruby <1.9
    end

    def self.target_method(name)
      define_method(:target_method){name}
    end

    def self.it_should_list_methods_with_visibility(visibility)
      it "should return the list of #{visibility} instance methods defined directly on a class" do
        temporary_class :C
        remove_methods C
        define_methods C, visibility => [:one, :two]
        Looksee.send(target_method, C).to_set.should == Set[:one, :two]
      end

      it "should return the list of #{visibility} instance methods defined directly on a module" do
        temporary_module :M
        remove_methods M
        define_methods M, visibility => [:one, :two]
        Looksee.send(target_method, M).to_set.should == Set[:one, :two]
      end

      it "should return the list of #{visibility} instance methods defined directly on a singleton class" do
        temporary_class :C
        c = C.new
        remove_methods c.singleton_class
        define_methods c.singleton_class, visibility => [:one, :two]
        Looksee.send(target_method, c.singleton_class).to_set.should == Set[:one, :two]
      end

      it "should return the list of #{visibility} instance methods defined directly on a class' singleton class" do
        temporary_class :C
        remove_methods C.singleton_class, :class_singleton => true
        define_methods C.singleton_class, visibility => [:one, :two]
        Looksee.send(target_method, C.singleton_class).to_set.should == Set[:one, :two]
      end

      # Worth checking as ruby keeps undef'd methods in method tables.
      it "should not return undefined methods" do
        temporary_class :C
        remove_methods C
        define_methods C, visibility => [:removed]
        C.send(:undef_method, :removed)
        Looksee.send(target_method, C).to_set.should == Set[]
      end
    end

    def self.it_should_not_list_methods_with_visibility(visibility1, visibility2)
      it "should not return any #{visibility1} or #{visibility2} instance methods" do
        temporary_class :C
        remove_methods C
        define_methods C, {visibility1 => [:a], visibility2 => [:b]}
        Looksee.send(target_method, C).to_set.should == Set[]
      end
    end

    describe ".internal_public_instance_methods" do
      target_method :internal_public_instance_methods
      it_should_list_methods_with_visibility :public
      it_should_not_list_methods_with_visibility :private, :protected
    end

    describe ".internal_protected_instance_methods" do
      target_method :internal_protected_instance_methods
      it_should_list_methods_with_visibility :protected
      it_should_not_list_methods_with_visibility :public, :private
    end

    describe ".internal_private_instance_methods" do
      target_method :internal_private_instance_methods
      it_should_list_methods_with_visibility :private
      it_should_not_list_methods_with_visibility :public, :protected
    end
  end
end

describe Looksee::LookupPath do
  before do
    Looksee.default_lookup_path_options = {}
  end

  include TemporaryClasses

  describe "#entries" do
    it "should contain an entry for each module in the object's lookup path" do
      object = Object.new
      temporary_class :C
      temporary_class :D
      Looksee.stubs(:lookup_modules).with(object).returns([C, D])
      Looksee::LookupPath.for(object).entries.map{|entry| entry.module_name}.should == %w'C D'
    end
  end

  describe "#inspect" do
    before do
      Looksee.stubs(:styles).returns(Hash.new{'%s'})
    end

    def stub_methods(mod, public, protected, private)
      Looksee.stubs(:internal_public_instance_methods   ).with(mod).returns(public)
      Looksee.stubs(:internal_protected_instance_methods).with(mod).returns(protected)
      Looksee.stubs(:internal_private_instance_methods  ).with(mod).returns(private)
    end

    describe "contents" do
      before do
        temporary_module :M
        temporary_class :C do
          include M
        end
        @object = Object.new
        Looksee.stubs(:lookup_modules).with(@object).returns([C, M])
        stub_methods(C, ['public1', 'public2'], ['protected1', 'protected2'], ['private1', 'private2'])
        stub_methods(M, ['public1', 'public2'], ['protected1', 'protected2'], ['private1', 'private2'])
      end

      it "should show only public instance methods when only public methods are requested" do
        lookup_path = Looksee::LookupPath.for(@object, :public => true, :overridden => true)
        lookup_path.inspect.should == <<-EOS.demargin
          |C
          |  public1  public2
          |M
          |  public1  public2
        EOS
      end

      it "should show modules and protected instance methods when only protected methods are requested" do
        lookup_path = Looksee::LookupPath.for(@object, :protected => true, :overridden => true)
        lookup_path.inspect.should == <<-EOS.demargin
          |C
          |  protected1  protected2
          |M
          |  protected1  protected2
        EOS
      end

      it "should show modules and private instance methods when only private methods are requested" do
        lookup_path = Looksee::LookupPath.for(@object, :private => true, :overridden => true)
        lookup_path.inspect.should == <<-EOS.demargin
          |C
          |  private1  private2
          |M
          |  private1  private2
        EOS
      end

      it "should show modules with public and private instance methods when only public and private methods are requested" do
        lookup_path = Looksee::LookupPath.for(@object, :public => true, :private => true, :overridden => true)
        lookup_path.inspect.should == <<-EOS.demargin
          |C
          |  private1  private2  public1  public2
          |M
          |  private1  private2  public1  public2
        EOS
      end

      it "should show singleton classes as class names in brackets" do
        Looksee.stubs(:lookup_modules).with(C).returns([C.singleton_class])
        stub_methods(C.singleton_class, ['public1', 'public2'], [], [])
        lookup_path = Looksee::LookupPath.for(C, :public => true)
        lookup_path.inspect.should == <<-EOS.demargin
          |[C]
          |  public1  public2
        EOS
      end

      it "should handle singleton classes of singleton classes correctly" do
        Looksee.stubs(:lookup_modules).with(C.singleton_class).returns([C.singleton_class.singleton_class])
        stub_methods(C.singleton_class.singleton_class, ['public1', 'public2'], [], [])
        lookup_path = Looksee::LookupPath.for(C.singleton_class, :public => true)
        lookup_path.inspect.should == <<-EOS.demargin
          |[[C]]
          |  public1  public2
        EOS
      end
    end

    describe "styles" do
      before do
        styles = {
          :module     => "`%s'",
          :public     => "{%s}",
          :protected  => "[%s]",
          :private    => "<%s>",
          :overridden => "(%s)",
        }
        Looksee.stubs(:styles).returns(styles)
      end

      it "should delimit each word with the configured delimiters" do
        temporary_class :C
        Looksee.stubs(:lookup_modules).returns([C])
        stub_methods(C, ['public'], ['protected'], ['private'])
        lookup_path = Looksee::LookupPath.for(Object.new, :public => true, :protected => true, :private => true, :overridden => true)
        lookup_path.inspect.should == <<-EOS.demargin
          |\`C\'
          |  <private>  [protected]  {public}
        EOS
      end
    end

    describe "layout" do
      it "should wrap method lists at the configured number of columns, sorting vertically first, and aligning into a grid" do
        temporary_class :C
        Looksee.stubs(:lookup_modules).returns([C])
        stub_methods(C, %w'aa b c dd ee f g hh i', [], [])
        lookup_path = Looksee::LookupPath.for(Object.new, :public => true)
        lookup_path.inspect(:width => 20).should == <<-EOS.demargin
          |C
          |  aa  c   ee  g   i
          |  b   dd  f   hh
        EOS
      end

      it "should lay the methods of each module out independently" do
        temporary_class :A
        temporary_class :B
        Looksee.stubs(:lookup_modules).returns([A, B])
        stub_methods(A, ['a', 'long_long_long_long_name'], [], [])
        stub_methods(B, ['long_long_long', 'short'], [], [])
        lookup_path = Looksee::LookupPath.for(Object.new, :public => true)
        lookup_path.inspect.should == <<-EOS.demargin
          |A
          |  a  long_long_long_long_name
          |B
          |  long_long_long  short
        EOS
      end
    end
  end
end
