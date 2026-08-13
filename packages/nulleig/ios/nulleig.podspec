Pod::Spec.new do |s|
  s.name             = 'nulleig'
  s.version          = '1.0.0'
  s.summary          = 'Real-time drone synthesis core for Null Eigenvalue.'
  s.description      = <<-DESC
The C++ synthesis engine and its audio device, compiled straight into the app
so that Dart FFI can resolve it out of the process image. No dynamic library,
so nothing extra has to be signed for a sideloaded build.
                       DESC
  s.homepage         = 'https://github.com/doctorspider42/null-eigenvalue'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Null Eigenvalue' => 'noreply@example.com' }

  s.source           = { :path => '.' }
  # Classes/ holds two forwarders that relatively include ../src. A podspec
  # cannot name paths outside its own directory, and the sources have to be
  # shared with the Android and desktop builds.
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  # Core Audio, and AVFoundation for the audio session miniaudio configures -
  # the playback category is what buys the app the right to keep running with
  # the screen off.
  s.frameworks       = 'AudioToolbox', 'AVFoundation', 'CoreAudio', 'CoreFoundation'
  s.libraries        = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) NE_WITH_MINIAUDIO=1',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../src" "$(PODS_TARGET_SRCROOT)/../src/third_party"',
    # The engine is only ever entered from an audio callback or a setter; there
    # is no exception path through it, and the reverb runs on every sample.
    'GCC_OPTIMIZATION_LEVEL' => '3',
  }
  s.swift_version = '5.0'
end
