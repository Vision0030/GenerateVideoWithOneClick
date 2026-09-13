# 一键成片 Demo
# Masonry：Auto Layout 的链式 DSL，界面约束都写在 mas_makeConstraints 里
platform :ios, '16.0'

target 'GenerateVideoWithOneClick' do
  pod 'Masonry', '~> 1.1'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
  end
end
