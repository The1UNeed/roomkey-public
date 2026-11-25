# migrate.sh — 中文
MSG[migrate.usage]="用法：
  psm migrate export [--output 文件] [--no-encrypt] 打包本机留存：节点、密钥、证书、Nginx、acme.sh（默认用口令加密）
  （import 和 push 已关闭：换服务器请在面板中添加新服务器并重建节点）"
MSG[migrate.nothing]="本机没有 PSM 配置，无可导出。"
MSG[migrate.exporting]="正在收集节点、密钥、证书和服务配置…"
MSG[migrate.pack_failed]="迁移包写入失败。"
MSG[migrate.exported]="迁移包已生成：%s（%s，%s 个节点）。"
MSG[migrate.secret_warn]="迁移包含有本机全部私钥和密码：请存放在只有你能读取的地方，只通过 SSH 传输。"
MSG[migrate.next_steps]="迁移包已保存在 %s。要换服务器，请在面板中添加新服务器并在那里重建节点。"
MSG[migrate.need_pass]="需要口令：请设置 PSM_MIGRATE_PASS，或在终端里运行（不加密导出：--no-encrypt）。"
MSG[migrate.ask_pass]="迁移包口令："
MSG[migrate.ask_pass2]="再输一次口令："
MSG[migrate.pass_mismatch]="口令为空，或两次输入不一致。"
MSG[migrate.menu.export]="导出本机打包（留存用）"
MSG[migrate.ask_encrypt]="迁移包含本机所有私钥和密码，用口令加密吗？"
