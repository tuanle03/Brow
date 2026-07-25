#!/usr/bin/env ruby
# frozen_string_literal: true

# Idempotently removes the unused "Pow" SPM package reference from
# Brow.xcodeproj. Zero `import Pow` anywhere in the repo, and no target
# has it as a product dependency (it was added as a package reference but
# never wired to a target) — a fully orphaned dependency. Safe to re-run.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../../Brow.xcodeproj', __dir__)

project = Xcodeproj::Project.open(PROJECT_PATH)

pow_ref = project.root_object.package_references.find do |ref|
  ref.respond_to?(:repositoryURL) && ref.repositoryURL&.include?('Pow')
end

if pow_ref.nil?
  puts "No 'Pow' package reference found, skipping"
else
  project.root_object.package_references.delete(pow_ref)
  pow_ref.remove_from_project
  puts "Removed 'Pow' package reference"
end

project.save
puts "Saved #{PROJECT_PATH}"
