#!/usr/bin/env ruby
# frozen_string_literal: true

# Registers the external-display-control sources (+ tests) in Brow.xcodeproj.
# `Brow/Managers` and `BrowTests` are classic PBXGroups, not file-system-
# synchronized groups, so new .swift files are invisible to the build until
# they are added to a Sources build phase — never hand-edit project.pbxproj.
#
# Idempotent, and only files that already exist on disk are added, so every
# task of the plan re-runs it after creating its files.
#
# Usage: ruby tools/xcodeproj/add_display_control_files.rb

require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(ROOT, 'Brow.xcodeproj')
SOURCE_DIR = File.join(ROOT, 'Brow', 'Managers', 'DisplayControl')
SOURCES = {
  'DDC' => %w[DDCPacket.swift DDCChannel.swift DDCWriteCoalescer.swift Arm64DDCTransport.swift],
  '' => %w[GammaDimmer.swift DisplayKeyBindings.swift ExternalDisplay.swift DisplayControlRouter.swift
           AudioOutput.swift DisplayRegistry.swift DisplayControlCenter.swift]
}.freeze
TESTS = %w[DDCPacketTests.swift DDCChannelTests.swift DDCWriteCoalescerTests.swift GammaDimmerTests.swift
           DisplayKeyBindingsTests.swift DisplayControlRouterTests.swift].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == 'Brow' } or raise "Could not find app target 'Brow'"
test_target = project.targets.find { |t| t.name == 'BrowTests' } or raise "Could not find test target 'BrowTests'"

def ensure_in_target(group, filename, target)
  ref = group.files.find { |f| f.path == filename } || group.new_file(filename)
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
end

managers = project.main_group['Brow']['managers'] or raise "Could not find 'Brow > managers' group"
dc_group = managers['DisplayControl'] || managers.new_group('DisplayControl', 'DisplayControl')

SOURCES.each do |subdir, files|
  group = subdir.empty? ? dc_group : (dc_group[subdir] || dc_group.new_group(subdir, subdir))
  files.each do |filename|
    next unless File.exist?(File.join(SOURCE_DIR, subdir, filename))

    ensure_in_target(group, filename, app_target)
    puts "Ensured DisplayControl/#{subdir.empty? ? '' : "#{subdir}/"}#{filename} in Brow"
  end
end

tests_group = project.main_group['BrowTests'] or raise "Could not find 'BrowTests' group"
TESTS.each do |filename|
  next unless File.exist?(File.join(ROOT, 'BrowTests', filename))

  ensure_in_target(tests_group, filename, test_target)
  puts "Ensured BrowTests/#{filename} in BrowTests"
end

project.save
puts "Saved #{PROJECT_PATH}"
