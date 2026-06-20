为 Forgejo Actions 提供 macOS runner。

sucai目录里有：
- forgejo：gitea 的一个分支，功能类似。
- forgejo-runner：forgejo 的 runner，类似 gitea-runner。
- forgejo-act：code.forgejo.org/forgejo/act
- tart：macOS 平台开 macOS 虚拟机的工具。

探索代码，评估能能否实现或基于现有的runner，实现一个支持forgejo的runner，对接tart，
为forgejo提供一个干净的、可恢复的macOS runner环境。
让forgejo的用户能够每个job都在干净的macOS环境下运行action。

暂不要修改或进行实现，如果有需求，可联网搜索相关资料。
告诉我runner和act的关系。
以及告诉我你打算，如果实现后，要怎么在宿主macOS进行部署这套runner，是独立安装tart命令和进行runner注册吗，runner又是通过什么方法与tart进行交互，是命令行吗？
如果可以做，做出来的成品是怎样的？就是像runner是一个二进制文件吗？

还需要克隆什么仓库到本地给你研究吗？
如果是use action那种step，是要怎么在macos虚拟机里执行的？常规runner是怎么操作的？
比如他是怎么在虚拟机里执行checkout来克隆代码的？
如果你需要一套测试环境，需要部署什么，部署完需要什么信息，可以告诉我，我会进行准备。