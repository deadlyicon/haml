#!/usr/bin/env ruby
require File.dirname(__FILE__) + '/../test_helper'
require 'sass/plugin'
require 'fileutils'

class SassPluginTest < Test::Unit::TestCase
  @@templates = %w{
    complex script parent_ref import alt
    subdir/subdir subdir/nested_subdir/nested_subdir
  }

  def setup
    FileUtils.mkdir tempfile_loc
    FileUtils.mkdir tempfile_loc(nil,"more_")
    set_plugin_opts
    Sass::Plugin.update_stylesheets
  end

  def teardown
    clean_up_sassc
    FileUtils.rm_r tempfile_loc
    FileUtils.rm_r tempfile_loc(nil,"more_")
  end

  @@templates.each do |name|
    define_method("test_template_renders_correctly (#{name})") do
      assert_renders_correctly(name)
    end
  end

  def test_no_update
    File.delete(tempfile_loc('basic'))
    assert Sass::Plugin.stylesheet_needs_update?('basic', template_loc, tempfile_loc)
    Sass::Plugin.update_stylesheets
    assert_stylesheet_updated 'basic'
  end

  def test_update_needed_when_modified
    sleep 1
    FileUtils.touch(template_loc('basic'))
    assert Sass::Plugin.stylesheet_needs_update?('basic', template_loc, tempfile_loc)
    Sass::Plugin.update_stylesheets
    assert_stylesheet_updated 'basic'
  end

  def test_update_needed_when_dependency_modified
    sleep 1
    FileUtils.touch(template_loc('basic'))
    assert Sass::Plugin.stylesheet_needs_update?('import', template_loc, tempfile_loc)
    Sass::Plugin.update_stylesheets
    assert_stylesheet_updated 'basic'
  end

  def test_full_exception_handling
    File.delete(tempfile_loc('bork1'))
    Sass::Plugin.update_stylesheets
    File.open(tempfile_loc('bork1')) do |file|
      assert_equal(<<CSS.strip, file.read.split("\n")[0...6].join("\n"))
/*
Syntax error: Undefined variable: "!bork".
        on line 2 of #{template_loc('bork1')}

1: bork
2:   :bork= !bork
CSS
    end
    File.delete(tempfile_loc('bork1'))
  end

  def test_nonfull_exception_handling
    old_full_exception = Sass::Plugin.options[:full_exception]
    Sass::Plugin.options[:full_exception] = false

    File.delete(tempfile_loc('bork1'))
    assert_raise(Sass::SyntaxError) {Sass::Plugin.update_stylesheets}
  ensure
    Sass::Plugin.options[:full_exception] = old_full_exception
  end
  
  def test_two_template_directories
    set_plugin_opts :template_location => {
      template_loc => tempfile_loc,
      template_loc(nil,'more_') => tempfile_loc(nil,'more_')
    }
    Sass::Plugin.update_stylesheets
    ['more1', 'more_import'].each { |name| assert_renders_correctly(name, :prefix => 'more_') }
  end

  def test_two_template_directories_with_line_annotations
    set_plugin_opts :line_comments => true,
                    :style => :nested,
                    :template_location => {
                      template_loc => tempfile_loc,
                      template_loc(nil,'more_') => tempfile_loc(nil,'more_')
                    }
    Sass::Plugin.update_stylesheets
    assert_renders_correctly('more1_with_line_comments', 'more1', :prefix => 'more_')
  end

  def test_merb_update
    begin
      require 'merb'
    rescue LoadError
      puts "\nmerb couldn't be loaded, skipping a test"
      return
    end
    
    require 'sass/plugin/merb'
    if defined?(MerbHandler)
      MerbHandler.send(:define_method, :process_without_sass) { |*args| }
    else
      Merb::Rack::Application.send(:define_method, :call_without_sass) { |*args| }
    end

    set_plugin_opts

    File.delete(tempfile_loc('basic'))
    assert Sass::Plugin.stylesheet_needs_update?('basic', template_loc, tempfile_loc)
    
    if defined?(MerbHandler)
      MerbHandler.new('.').process nil, nil
    else
      Merb::Rack::Application.new.call(::Rack::MockRequest.env_for('/'))
    end

    assert_stylesheet_updated 'basic'
  end

  def test_doesnt_render_partials
    assert !File.exists?(tempfile_loc('_partial'))
  end

  ## Regression

  def test_cached_dependencies_update
    FileUtils.mv(template_loc("basic"), template_loc("basic", "more_"))
    set_plugin_opts :load_paths => [result_loc, template_loc(nil, "more_")]

    sleep 1
    FileUtils.touch(template_loc("basic", "more_"))
    assert Sass::Plugin.stylesheet_needs_update?("import", template_loc, tempfile_loc)
    Sass::Plugin.update_stylesheets
    assert_renders_correctly("import")
  ensure
    FileUtils.mv(template_loc("basic", "more_"), template_loc("basic"))
  end

 private

  def assert_renders_correctly(*arguments)
    options = arguments.last.is_a?(Hash) ? arguments.pop : {}
    prefix = options[:prefix]
    result_name = arguments.shift
    tempfile_name = arguments.shift || result_name
    expected_lines = File.read(result_loc(result_name, prefix)).split("\n")
    actual_lines = File.read(tempfile_loc(tempfile_name, prefix)).split("\n")

    if actual_lines.first == "/*" && expected_lines.first != "/*"
      assert(false, actual_lines[0..actual_lines.enum_with_index.find {|l, i| l == "*/"}.last].join("\n"))
    end

    expected_lines.zip(actual_lines).each_with_index do |pair, line|
      message = "template: #{result_name}\nline:     #{line + 1}"
      assert_equal(pair.first, pair.last, message)
    end
    if expected_lines.size < actual_lines.size
      assert(false, "#{actual_lines.size - expected_lines.size} Trailing lines found in #{tempfile_name}.css: #{actual_lines[expected_lines.size..-1].join('\n')}")
    end
  end

  def assert_stylesheet_updated(name)
    assert !Sass::Plugin.stylesheet_needs_update?(name, template_loc, tempfile_loc)

    # Make sure it isn't an exception
    expected_lines = File.read(result_loc(name)).split("\n")
    actual_lines = File.read(tempfile_loc(name)).split("\n")
    if actual_lines.first == "/*" && expected_lines.first != "/*"
      assert(false, actual_lines[0..actual_lines.enum_with_index.find {|l, i| l == "*/"}.last].join("\n"))
    end
  end

  def template_loc(name = nil, prefix = nil)
    if name
      absolutize "#{prefix}templates/#{name}.sass"
    else
      absolutize "#{prefix}templates"
    end
  end

  def tempfile_loc(name = nil, prefix = nil)
    if name
      absolutize "#{prefix}tmp/#{name}.css"
    else
      absolutize "#{prefix}tmp"
    end
  end

  def result_loc(name = nil, prefix = nil)
    if name
      absolutize "#{prefix}results/#{name}.css"
    else
      absolutize "#{prefix}results"
    end
  end

  def absolutize(file)
    "#{File.dirname(__FILE__)}/#{file}"
  end

  def set_plugin_opts(overrides = {})
    Sass::Plugin.options = {
      :template_location => template_loc,
      :css_location => tempfile_loc,
      :style => :compact,
      :load_paths => [result_loc],
      :always_update => true,
    }.merge(overrides)
  end

  def wait_a_tick
    time = Time.now
    loop {break if Time.now.sec != time.sec}
  end
end

module Sass::Plugin
  class << self
    public :stylesheet_needs_update?
  end
end

class Sass::Engine
  alias_method :old_render, :render

  def render
    raise "bork bork bork!" if @template[0] == "{bork now!}"
    old_render
  end
end
