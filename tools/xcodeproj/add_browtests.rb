#!/usr/bin/env ruby
# Adds the `BrowTests` unit-test target (hosted by `Brow`) to Brow.xcodeproj
# using the `xcodeproj` gem — never hand-edit project.pbxproj.
#
# Idempotent: safe to re-run; skips work that's already done.
#
# Usage: ruby tools/xcodeproj/add_browtests.rb

require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(ROOT, 'Brow.xcodeproj')
TEST_TARGET_NAME = 'BrowTests'
HOST_TARGET_NAME = 'Brow'

project = Xcodeproj::Project.open(PROJECT_PATH)

host_target = project.targets.find { |t| t.name == HOST_TARGET_NAME }
raise "Host target '#{HOST_TARGET_NAME}' not found" unless host_target

host_swift_version = host_target.build_configurations.first.build_settings['SWIFT_VERSION'] || '5.0'

test_target = project.targets.find { |t| t.name == TEST_TARGET_NAME }

if test_target
  puts "Target '#{TEST_TARGET_NAME}' already exists — skipping creation."
else
  test_target = project.new_target(
    :unit_test_bundle,
    TEST_TARGET_NAME,
    :osx,
    '14.0',
    project.products_group,
    :swift
  )

  test_target.build_configurations.each do |config|
    config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'tuanle03.Brow.BrowTests'
    config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
    config.build_settings['SWIFT_VERSION'] = host_swift_version
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Brow.app/Contents/MacOS/Brow'
    config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  end

  test_target.add_dependency(host_target)

  puts "Created target '#{TEST_TARGET_NAME}'."
end

# --- Add BrowTests/SmokeTests.swift to the target's Sources phase ---

tests_group = project.main_group.children.find { |c| c.respond_to?(:display_name) && c.display_name == TEST_TARGET_NAME }
tests_group ||= project.main_group.new_group(TEST_TARGET_NAME, TEST_TARGET_NAME)

relative_path = 'SmokeTests.swift'

file_ref = tests_group.children.find { |c| c.respond_to?(:path) && c.path == relative_path }
file_ref ||= tests_group.new_reference(relative_path)

already_in_sources = test_target.source_build_phase.files_references.include?(file_ref)
test_target.add_file_references([file_ref]) unless already_in_sources

project.save

# --- Scheme note ---
# This repo has no committed .xcscheme files (`*.xcscheme` is gitignored —
# see .gitignore) and relies on Xcode/xcodebuild's autocreated scheme, which
# is regenerated at build time by introspecting the project. Verified
# empirically: `xcodebuild test -scheme Brow -only-testing:BrowTests`
# discovers and runs BrowTests via the autocreated scheme with no scheme
# file on disk, so no scheme file needs to be created or committed here.

puts 'Done.'
