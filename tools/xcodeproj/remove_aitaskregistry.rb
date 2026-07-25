#!/usr/bin/env ruby
# frozen_string_literal: true

# Idempotently removes AITaskRegistry.swift's file reference and Sources
# build-file entry from Brow.xcodeproj. Dead code: `AITaskRegistry` (the
# class) has no call sites left anywhere in the repo — only its own
# declaration and a historical doc-comment mention survive — after the v8
# panel replaced the old AIApproveSection card. Safe to re-run.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../../Brow.xcodeproj', __dir__)
FILENAME = 'AITaskRegistry.swift'

project = Xcodeproj::Project.open(PROJECT_PATH)

file_ref = project.files.find { |f| f.path == FILENAME }

if file_ref.nil?
  puts "No file reference for #{FILENAME}, skipping"
else
  project.targets.each do |target|
    target.source_build_phase.files.each do |bf|
      next unless bf.file_ref == file_ref
      target.source_build_phase.remove_build_file(bf)
      puts "Removed #{FILENAME} from '#{target.name}' Sources build phase"
    end
  end
  file_ref.remove_from_project
  puts "Removed file reference for #{FILENAME}"
end

project.save
puts "Saved #{PROJECT_PATH}"
