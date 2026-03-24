require 'xcodeproj'

project_path = '/Users/uxin/Desktop/无名高地/fileReadAction/GCSPlayer/GCSPlayer.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

# 1. 链接系统库
system_frameworks = ['AudioToolbox', 'VideoToolbox', 'MetalKit', 'AVFoundation']
system_frameworks.each do |framework|
  unless target.frameworks_build_phase.files.find { |f| f.file_ref && f.file_ref.path == "#{framework}.framework" }
    file_ref = project.frameworks_group.new_reference("System/Library/Frameworks/#{framework}.framework")
    file_ref.source_tree = 'SDKROOT'
    target.frameworks_build_phase.add_file_reference(file_ref)
  end
end

system_libs = ['libz.tbd', 'libbz2.tbd', 'libiconv.tbd']
system_libs.each do |lib|
  unless target.frameworks_build_phase.files.find { |f| f.file_ref && f.file_ref.path == lib }
    file_ref = project.frameworks_group.new_reference("usr/lib/#{lib}")
    file_ref.source_tree = 'SDKROOT'
    target.frameworks_build_phase.add_file_reference(file_ref)
  end
end

# 2. 链接 FFmpeg XCFrameworks
frameworks_group = project.main_group.find_subpath('Frameworks', true)
ffmpeg_libs = ['libavcodec', 'libavformat', 'libavutil', 'libswresample', 'libswscale']

ffmpeg_libs.each do |lib|
  xcframework_path = "/Users/uxin/Desktop/无名高地/fileReadAction/GCSPlayer/FFmpeg.xcframework/#{lib}.xcframework"
  unless target.frameworks_build_phase.files.find { |f| f.file_ref && f.file_ref.path == xcframework_path }
    file_ref = frameworks_group.new_reference(xcframework_path)
    file_ref.source_tree = '<group>'
    target.frameworks_build_phase.add_file_reference(file_ref)
  end
end

project.save
puts "Libraries linked successfully!"