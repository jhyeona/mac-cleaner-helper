# 비우 (Biu)

**Mac 개발 환경 정리 도우미** — 큰 파일만 나열하지 않고 무엇인지, 왜 커졌는지,
정리하면 어떤 영향이 있는지 설명하는 macOS 14+ 네이티브 앱입니다.

## 구현된 기능

- 여러 개발 폴더의 보안 범위 북마크 등록
- 앱을 다시 열어도 등록 폴더와 마지막 완료 분석 결과 복원
- 논리 크기와 실제 할당 크기를 분리하는 스트리밍 분석, 진행률과 취소
- 숨김 항목, 패키지, 심볼릭 링크, 외장 볼륨 경계, 접근 오류 구분
- Apple, Android/JVM, Web, Python, Rust/Go/Ruby, Container/Infra, IDE 탐지 팩
- `재생성 가능`, `확인 필요`, `보호 대상` 안전 판정과 영향·복구 설명
- 보호 경로 및 심볼릭 링크 재검증, 파일 식별자 변경 감지
- 개인 파일의 휴지통 이동과 검증된 캐시만 허용하는 선택형 즉시 삭제
- 셸을 사용하지 않는 Xcode Simulator, Docker, Podman, Homebrew 명령 허용 목록
- 실행 중인 관련 앱 감지, 실행 전 명령·대상·영향 최종 확인
- 앱 관리: 기본 앱 폴더와 로컬 Spotlight 검색, 이름·경로 검색과 용량 정렬, 다른 설치 폴더 추가
- App Store 밖에서 설치한 일반 앱도 바구니에서 확인 후 휴지통으로 이동 (앱 데이터·설정 유지)
- 시스템 앱·비우 자체·심볼릭 링크 보호, 삭제 실행 직전 실행 중인 앱 재검사
- 예상 확보량과 실제 디스크 여유 공간 변화를 분리한 SwiftData 정리 기록
- 기록 JSON 내보내기와 전체 삭제
- 상태별 비우 안내, 모션 감소, 선택형 비활성 플로팅 패널과 조용한 모드
- 선택형 전체 디스크 분석과 권한·소요 시간 사전 안내
- 한국어 기반 String Catalog와 영어 확장 골격
- 한글을 포함한 Terrarum Sans Bitmap v1.16.2 앱 내장 폰트

분석과 판정은 로컬에서만 수행하며 경로, 파일명, 메타데이터 또는 텔레메트리를
외부로 보내지 않습니다. 어떤 항목도 자동 선택하지 않습니다.

앱 관리는 `.app` 번들을 대상으로 하며 CLI 패키지·드라이버 전체를 나열하는 기능은
아닙니다. Spotlight 색인에서 빠진 위치는 ‘다른 폴더’로 추가할 수 있습니다.
권한을 우회하거나 관리자 권한을 요청하지 않습니다. 별도 제거 도구가 있는 앱은
제작사의 도구를 권장하며, 휴지통을 비우기 전에는 실제 여유 공간이 늘지 않습니다.
앱 목록은 메모리에만 보관하고, 사용자가 실행한 정리 기록만 기존 로컬 기록에 남깁니다.

## 실행

```bash
swift run MacCleanHelper
```

실제 macOS 앱 번들로 실행하려면 다음 명령을 사용합니다.

```bash
scripts/build-app.sh debug
open .build/Biu-debug.app
```

평소 실행하는 `~/Applications/비우.app`까지 갱신하려면 비우(개발용 앱 포함)를
종료하고 아래 명령을 실행합니다. 빌드만 하면 기존 설치본은 바뀌지 않습니다.

```bash
scripts/install-local.sh
open ~/Applications/비우.app
```

설치 스크립트는 서명을 검증한 새 앱으로 교체하고 이전 앱을
`.build/local-install-backups/`에 보관합니다. 등록 폴더·설정·기록은 변경하지
않습니다. 백업과 빌드 결과는 `.gitignore`의 `.build/` 규칙으로 제외됩니다.

## 테스트

```bash
swift test
```

테스트는 스캐너 스트리밍·크기 계산·심볼릭 링크, 경로 보호와 충돌,
탐지 팩, 명령 허용 목록, 즉시 삭제 제한, SwiftData 기록을 검증합니다.

## 서드파티 폰트

화면 글꼴은 **Terrarum Sans Bitmap v1.16.2**를 사용합니다. 폰트는 SIL Open
Font License 1.1로 배포되며, 저작권 고지와 라이선스 전문은 앱 리소스의
`ThirdParty/TerrarumSansBitmap-LICENSE.md`에 포함되어 있습니다.

## 배포 전 남은 작업

현재 저장소는 Swift Package 기반 개발 빌드입니다. Developer ID 서명·공증,
Hardened Runtime 설정, Sparkle 2 서명 피드, 실제 10만 파일 성능 계측과
VoiceOver/UI 자동화는 배포용 Xcode 프로젝트 및 서명 자격 증명과 함께 RC에서
완료해야 합니다. 관리자 권한과 루트 헬퍼는 사용하지 않습니다.

상세 제품 원칙은 [docs/PRODUCT_PLAN.md](docs/PRODUCT_PLAN.md), 캐릭터 기준은
[docs/CHARACTER.md](docs/CHARACTER.md)에서 확인할 수 있습니다.
