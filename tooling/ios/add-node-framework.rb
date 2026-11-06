# 把 NodeMobile.xcframework 挂进 Runner:文件引用 + 链接 + 嵌入。
# 只在 CI 的 local-engine 分支用到;工程文件里不留绝对路径。
require 'xcodeproj'

project = Xcodeproj::Project.open('app/ios/Runner.xcodeproj')
runner = project.targets.find { |t| t.name == 'Runner' }
path = 'vendor/NodeMobile.xcframework'

group = project.main_group.children.find { |g| g.display_name == 'vendor' }
group ||= project.main_group.new_group('vendor', 'vendor')

ref = group.files.find { |f| f.path == 'NodeMobile.xcframework' } || group.new_reference(path)
ref.source_tree = '<group>'

# 工程里有 nil 引用(历史上删过文件),先 compact 再比名字,否则 display_name 落到 nil 上
unless runner.frameworks_build_phase.files_references.compact.any? { |r| r.display_name == 'NodeMobile.xcframework' }
  runner.frameworks_build_phase.add_file_reference(ref)
end

embed = runner.copy_files_build_phases.find { |p| p.dst_subfolder_spec.to_s == '10' }
embed ||= runner.new_copy_files_build_phase('Embed Frameworks')
embed.dst_subfolder_spec = '10'
unless embed.files_references.compact.any? { |r| r.display_name == 'NodeMobile.xcframework' }
  bf = embed.add_file_reference(ref)
  bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
end

project.save
puts 'NodeMobile.xcframework linked into Runner'
