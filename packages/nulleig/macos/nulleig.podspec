Pod::Spec.new do |s|
  s.name             = 'nulleig'
  s.version          = '1.0.0'
  s.summary          = 'Real-time drone synthesis core for Null Eigenvalue.'
  s.description      = <<-DESC
The C++ synthesis engine and its audio device. Flutter's generated Podfile uses
`use_frameworks!`, so on the Mac this becomes an embedded dynamic framework
whose symbols dlsym can see across the process - which is what the Dart binding
probes for before it falls back to opening the framework by name.
                       DESC
  s.homepage         = 'https://github.com/doctorspider42/null-eigenvalue'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Null Eigenvalue' => 'noreply@example.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'

  # No AVFoundation. The audio-session dance in api.cpp is guarded by
  # TARGET_OS_IPHONE, because a Mac has no session to configure and nothing to
  # negotiate for the right to keep making sound while the screen is off.
  s.frameworks       = 'AudioToolbox', 'AudioUnit', 'CoreAudio', 'CoreFoundation'
  s.libraries        = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) NE_WITH_MINIAUDIO=1',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../src" "$(PODS_TARGET_SRCROOT)/../src/third_party"',
    'GCC_OPTIMIZATION_LEVEL' => '3',
  }
  s.swift_version = '5.0'
end
