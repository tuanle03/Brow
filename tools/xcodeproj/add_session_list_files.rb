#!/usr/bin/env ruby
# frozen_string_literal: true

# `Brow/components/AI` (and `BrowTests`) are classic PBXGroups, not
# file-system-synchronized groups, so new .swift files dropped on disk
# there are invisible to the build until registered in a Sources build
# phase. This script does that for Task 2.5's session list + row (+ the
# `AgentSession` presentation extension + its test), via the `xcodeproj`
# gem — never hand-edit project.pbxproj.
#
# Idempotent: safe to re-run; skips work that's already done.
#
# Usage: ruby tools/xcodeproj/add_session_list_files.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../../Brow.xcodeproj', __dir__)
CORE_SOURCE_FILES = %w[
  AgentSession+Presentation.swift
].freeze
V8_SOURCE_FILES = %w[
  SessionRowView.swift
  SessionListView.swift
].freeze
TEST_FILES = %w[
  SessionListDerivationTests.swift
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == 'Brow' }
raise "Could not find app target 'Brow'" unless app_target

test_target = project.targets.find { |t| t.name == 'BrowTests' }
raise "Could not find test target 'BrowTests'" unless test_target

def ensure_files(group, filenames, target)
  filenames.each do |filename|
    file_ref = group.files.find { |f| f.path == filename }
    file_ref ||= group.new_file(filename)
    target.add_file_references([file_ref]) unless target.source_build_phase.files_references.include?(file_ref)
  end
end

# --- 1. Brow/components/AI/Core/AgentSession+Presentation.swift -------------

core_group = project.main_group['Brow']['components']['AI']['Core']
raise "Could not find 'Brow > components > AI > Core' group" unless core_group

ensure_files(core_group, CORE_SOURCE_FILES, app_target)
puts "Ensured #{CORE_SOURCE_FILES.join(', ')} are in the Brow target's Sources phase"

# --- 2. Brow/components/AI/Views/v8 group + source files --------------------

views_group = project.main_group['Brow']['components']['AI']['Views']
raise "Could not find 'Brow > components > AI > Views' group" unless views_group

v8_group = views_group['v8']
raise "Could not find 'v8' group under Brow/components/AI/Views" unless v8_group

ensure_files(v8_group, V8_SOURCE_FILES, app_target)
puts "Ensured #{V8_SOURCE_FILES.join(', ')} are in the Brow target's Sources phase"

# --- 3. BrowTests/SessionListDerivationTests.swift ---------------------------

tests_group = project.main_group['BrowTests']
raise "Could not find 'BrowTests' group" unless tests_group

ensure_files(tests_group, TEST_FILES, test_target)
puts "Ensured #{TEST_FILES.join(', ')} are in the BrowTests target's Sources phase"

project.save
puts "Saved #{PROJECT_PATH}"
