# Note7_TV

[AutoDeck](AutoDeck/) 是 Redmi Note 7（Android 16 / KernelSU）的 DisplayLink OTG 自动化模块。手机通过 OTG 连接 DisplayLink 扩展坞，扩展坞再通过 HDMI 连接显示器。视频输出由 DisplayLink Presenter 提供。模块在检测到扩展坞和有效镜像后启动配置的应用、临时切换默认启动器，并支持可选的 Android 镜像源尺寸和限时关屏。

运行时只需要手机、DisplayLink 扩展坞和显示器。拔出手机侧 OTG 或结束镜像会自动恢复。只拔 HDMI 时，如果 Presenter 仍保持镜像，模块依靠限时机制恢复。

[安装、配置、验证和救援步骤](AutoDeck/README.md)

## 创建并推送公共仓库

在新工作区中准备好本项目文件后运行以下命令。需要 Git 和已登录 GitHub 的 GitHub CLI。

```bash
git init -b main
git add -- .gitattributes .gitignore README.md AutoDeck
git commit -m "Add AutoDeck USB display relay"
gh auth login
gh repo create Note7_TV --public --source=. --remote=origin
git push -u origin main
```

如果仓库已经创建，克隆后在已有 Git 工作区内提交和推送即可。 [GitHub CLI 创建仓库文档](https://cli.github.com/manual/gh_repo_create)
