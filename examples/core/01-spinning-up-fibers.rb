# frozen_string_literal: true

require 'bundler/setup'

require 'polyphony'

def nap(tag, t)
  puts "#{Time.now} #{tag} napping for #{t} seconds..."
  sleep t
  puts "#{Time.now} #{tag} done napping"
end

# We launch two concurrent fibers, each sleeping for the given duration.
spin { nap(:a, 1) }
spin { nap(:b, 2) }

# Calling suspend will block until all child fibers have terminated
suspend