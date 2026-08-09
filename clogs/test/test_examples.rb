# frozen_string_literal: true

require_relative "test_helper"

# End-to-end: every example really opens a window, lays itself out, paints and
# shuts down cleanly. This is the test that catches FFI mistakes, since those
# usually abort the process rather than raise.
class TestExamples < Minitest::Test
  EXAMPLES = Dir[File.expand_path("../examples/*.rb", __dir__)].sort

  def test_there_are_examples
    refute_empty EXAMPLES
  end

  EXAMPLES.each do |path|
    name = File.basename(path, ".rb")
    define_method("test_example_#{name}_runs") do
      skip "needs a display" unless ENV["DISPLAY"]

      err, status = ClogsTest.run_app(path)
      noise = ClogsTest.meaningful_stderr(err)

      assert status.success?, "#{name} exited with #{status.exitstatus}:\n#{err}"
      assert_empty noise, "#{name} wrote to stderr:\n#{noise.join}"
    end
  end
end
