#!/usr/bin/env ruby
# frozen_string_literal: true

# Idempotently removes the auto-linked Cocoa.framework from BrowAgentHook's
# Frameworks build phase. `xcodeproj` linked it in when the target was
# created; BrowAgentHook's 3 sources only `import Foundation`, and the
# framework file-ref path is SDK-version-pinned (a portability smell), so it
# has no reason to stay. Safe to re-run: no-ops if already removed.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../../Brow.xcodeproj', __dir__)

project = Xcodeproj::Project.open(PROJECT_PATH)

hook_target = project.targets.find { |t| t.name == 'BrowAgentHook' }
raise "Could not find target 'BrowAgentHook'" unless hook_target

frameworks_phase = hook_target.frameworks_build_phase
cocoa_build_file = frameworks_phase.files.find { |f| f.file_ref&.display_name == 'Cocoa.framework' }

if cocoa_build_file
  frameworks_phase.remove_build_file(cocoa_build_file)
  puts "Removed Cocoa.framework from 'BrowAgentHook' Frameworks build phase"
else
  puts "'BrowAgentHook' Frameworks build phase has no Cocoa.framework link, skipping"
end

project.save
puts "Saved #{PROJECT_PATH}"
