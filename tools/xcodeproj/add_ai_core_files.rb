#!/usr/bin/env ruby
# frozen_string_literal: true

# `Brow/components/AI` (and `BrowTests`) are classic PBXGroups, not
# file-system-synchronized groups, so new .swift files dropped on disk
# there are invisible to the build until registered in a Sources build
# phase. This script does that for Task 1.2's new value-type Core files
# (+ their test), via the `xcodeproj` gem — never hand-edit project.pbxproj.
#
# Idempotent: safe to re-run; skips work that's already done.
#
# Usage: ruby tools/xcodeproj/add_ai_core_files.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../../Brow.xcodeproj', __dir__)
CORE_SOURCE_FILES = %w[
  AgentTool.swift
  SessionPhase.swift
  JumpTarget.swift
  PermissionModels.swift
  QuestionModels.swift
  AgentSession.swift
  AgentEvent.swift
  SessionState.swift
  ClaudeEventMapping.swift
  AIAppModel.swift
].freeze
TEST_FILES = %w[
  ValueTypeTests.swift
  AgentSessionVisibilityTests.swift
  AgentEventCodableTests.swift
  SessionStateTests.swift
  ClaudeEventMappingTests.swift
  AIAppModelTests.swift
  AICoreEndToEndTests.swift
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == 'Brow' }
raise "Could not find app target 'Brow'" unless app_target

test_target = project.targets.find { |t| t.name == 'BrowTests' }
raise "Could not find test target 'BrowTests'" unless test_target

# --- 1. Brow/components/AI/Core group + source files -----------------------

ai_group = project.main_group['Brow']['components']['AI']
raise "Could not find 'Brow > components > AI' group" unless ai_group

core_group = ai_group['Core']
if core_group.nil?
  core_group = ai_group.new_group('Core', 'Core')
  puts "Created group 'Core' under Brow/components/AI"
end

CORE_SOURCE_FILES.each do |filename|
  file_ref = core_group.files.find { |f| f.path == filename }
  file_ref ||= core_group.new_file(filename)
  app_target.add_file_references([file_ref]) unless app_target.source_build_phase.files_references.include?(file_ref)
end
puts "Ensured #{CORE_SOURCE_FILES.join(', ')} are in the Brow target's Sources phase"

# --- 2. BrowTests/ValueTypeTests.swift --------------------------------------

tests_group = project.main_group['BrowTests']
raise "Could not find 'BrowTests' group" unless tests_group

TEST_FILES.each do |filename|
  test_file_ref = tests_group.files.find { |f| f.path == filename }
  test_file_ref ||= tests_group.new_file(filename)
  unless test_target.source_build_phase.files_references.include?(test_file_ref)
    test_target.add_file_references([test_file_ref])
  end
end
puts "Ensured #{TEST_FILES.join(', ')} are in the BrowTests target's Sources phase"

project.save
puts "Saved #{PROJECT_PATH}"
