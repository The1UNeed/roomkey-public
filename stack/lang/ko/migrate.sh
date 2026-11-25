# migrate.sh — 한국어
MSG[migrate.usage]="사용법:
  psm migrate export [--output 파일] [--no-encrypt] 이 서버를 보관용으로 묶기: 노드, 키, 인증서, Nginx, acme.sh (--no-encrypt가 없으면 암호로 암호화)
  (import와 push는 꺼져 있음: 서버 이전은 패널에서 새 서버를 추가하고 노드를 다시 만듭니다)"
MSG[migrate.nothing]="이 서버에 PSM 설정이 없어 내보낼 것이 없습니다."
MSG[migrate.exporting]="노드, 키, 인증서, 서비스 설정을 모으는 중…"
MSG[migrate.pack_failed]="번들을 쓸 수 없습니다."
MSG[migrate.exported]="번들 생성: %s (%s, 노드 %s 개)."
MSG[migrate.secret_warn]="이 번들에는 이 서버의 모든 개인 키와 비밀번호가 들어 있습니다: 본인만 읽을 수 있는 곳에 보관하고 SSH로만 복사하세요."
MSG[migrate.next_steps]="번들이 %s 에 보관되었습니다. 서버를 옮기려면 패널에서 새 서버를 추가하고 거기서 노드를 다시 만드세요."
MSG[migrate.need_pass]="암호가 필요합니다: PSM_MIGRATE_PASS 를 설정하거나 터미널에서 실행하세요 (암호화하지 않으려면 --no-encrypt)."
MSG[migrate.ask_pass]="번들 암호:"
MSG[migrate.ask_pass2]="암호 다시 입력:"
MSG[migrate.pass_mismatch]="암호가 비어 있거나 두 입력이 다릅니다."
MSG[migrate.menu.export]="이 서버의 번들 내보내기 (보관용)"
MSG[migrate.ask_encrypt]="이 번들에는 이 서버의 모든 개인 키와 비밀번호가 들어 있습니다. 암호로 암호화할까요?"
