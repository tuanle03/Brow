#!/usr/bin/env ruby
# frozen_string_literal: true

# Idempotently adds the BrowAgentHook command-line-tool target to Brow.xcodeproj:
#   1. New target `BrowAgentHook` (com.apple.product-type.tool), macOS 14.0, Swift 6.
#   2. A `BrowAgentHook` group with its 3 source files added to that target's Sources phase.
#   3. `BrowAgentHook` added as a target dependency of the `Brow` app target.
#   4. A Copy Files build phase on `Brow` that embeds the BrowAgentHook binary into
#      Brow.app/Contents/Helpers.
#
# Safe to re-run: every step checks for the existing object before creating one.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../../Brow.xcodeproj', __dir__)
SOURCE_FILES = %w[main.swift HookRuntimeContext.swift BridgePost.swift].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == 'Brow' }
raise "Could not find app target 'Brow'" unless app_target

# --- 1. Target -------------------------------------------------------------

hook_target = project.targets.find { |t| t.name == 'BrowAgentHook' }
if hook_target.nil?
  hook_target = project.new_target(:command_line_tool, 'BrowAgentHook', :osx, '14.0')
  hook_target.build_configuration_list.build_configurations.each do |config|
    config.build_settings['SWIFT_VERSION'] = '6.0'
    config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
    config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  end
  puts "Created target 'BrowAgentHook'"
else
  puts "Target 'BrowAgentHook' already exists, skipping creation"
end

# --- 2. Group + source files -------------------------------------------------

group = project.main_group['BrowAgentHook']
if group.nil?
  group = project.main_group.new_group('BrowAgentHook', 'BrowAgentHook')
  puts "Created group 'BrowAgentHook'"
end

SOURCE_FILES.each do |filename|
  file_ref = group.files.find { |f| f.path == filename }
  file_ref ||= group.new_file(filename)
  hook_target.add_file_references([file_ref])
end
puts "Ensured #{SOURCE_FILES.join(', ')} are in the BrowAgentHook target's Sources phase"

# --- 3. Target dependency on Brow -------------------------------------------

app_target.add_dependency(hook_target)
puts "Ensured 'BrowAgentHook' is a dependency of 'Brow'"

# --- 4. Copy Files phase: embed into Brow.app/Contents/Helpers -------------

embed_phase = app_target.copy_files_build_phases.find { |p| p.dst_path == '$(CONTENTS_FOLDER_PATH)/Helpers' }
if embed_phase.nil?
  embed_phase = app_target.new_copy_files_build_phase('Embed BrowAgentHook')
  # Mirrors the existing "Embed XPC Services" phase's pattern for a custom
  # destination folder under the app bundle: dst_subfolder_spec 16 (Products
  # Directory) + an explicit $(CONTENTS_FOLDER_PATH)-relative dst_path.
  embed_phase.symbol_dst_subfolder_spec = :products_directory
  embed_phase.dst_path = '$(CONTENTS_FOLDER_PATH)/Helpers'
  puts "Created 'Embed BrowAgentHook' Copy Files phase (-> Contents/Helpers)"
else
  puts "'Embed BrowAgentHook' Copy Files phase already exists"
end

build_file = embed_phase.add_file_reference(hook_target.product_reference, true)
build_file.settings ||= {}
build_file.settings['ATTRIBUTES'] = ['CodeSignOnCopy']

project.save
puts "Saved #{PROJECT_PATH}"
