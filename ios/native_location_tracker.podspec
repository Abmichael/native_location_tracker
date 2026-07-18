Pod::Spec.new do |s|
  s.name             = 'native_location_tracker'
  s.version          = '0.4.0'
  s.summary          = 'Native-first background location tracking for Flutter'
  s.description      = <<-DESC
  A Flutter plugin for robust background location tracking with native
  persistence, batch uploads, adaptive sampling, and motion-state pacing.
                       DESC
  s.homepage         = 'https://github.com/example/native_location_tracker'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Name' => 'you@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'native_location_tracker/Sources/native_location_tracker/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'

  s.frameworks = 'CoreLocation', 'CoreMotion', 'BackgroundTasks', 'Network'
end
