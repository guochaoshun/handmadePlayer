require 'xcodeproj'

project_path = '/Users/uxin/Desktop/无名高地/fileReadAction/GCSPlayer/GCSPlayer.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# 找到主 target
target = project.targets.first

# 找到 GCSPlayer group
group = project.main_group.find_subpath('GCSPlayer', true)

# 要添加的文件列表
files_to_add = [
  'GCSPlayer-Bridging-Header.h',
  'YCAudioPlayer.h',
  'YCAudioPlayer.m',
  'YCCorePlayer.h',
  'YCCorePlayer.m',
  'YCMediaPlayer.swift',
  'YCMetalView.swift',
  'Shaders.metal'
]

# 配置 Bridging Header
target.build_configurations.each do |config|
  config.build_settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'GCSPlayer/GCSPlayer-Bridging-Header.h'
end

project.save
puts "Project updated successfully!"
