# Ubuntu 26.04 打包

这是 [tencentyun/cosfs](https://github.com/tencentyun/cosfs) 的公开 fork，只负责在 Ubuntu 26.04 amd64 上编译并发布安装包。许可证仍是 GPL-2.0。

GitHub Actions 每 6 小时拉取上游默认分支。有新提交就合并、构建、发版。上游 60 天没有新提交时，会在仓库里记一次检查，避免 GitHub 因长期无活动关掉定时任务。

安装包在 [Releases](https://github.com/Marco9442/cosfs/releases)。

```bash
sudo apt-get install -y ./cosfs_*_amd64.deb
```

`configure.ac` 里的弯引号只在构建目录里换成直引号，不改挂载行为。
