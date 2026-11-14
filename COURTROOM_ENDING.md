# 법정 결말 모션

라운드가 끝나면 두 가방을 하나씩 정산하는 연출(아래 "정산 연출")을 보여 준 뒤, 최종 금액으로 승패를 정하고 법정 링에서 결과 모션을 재생합니다. 영상이나 이미지 카드가 아니라 `assets/endings`의 GLB 관절 애니메이션입니다(배치·카메라 값은 `ending_assets_manifest.json`).

## 장면과 API

`res://courtroom_ending.tscn` (`courtroom_ending.gd`, CanvasLayer)

- `show_settlement(rows)`: 정산 연출을 시작합니다. 끝나면 판결을 띄우고 `verdict_reached(outcome)`를 보냅니다. `final_gold`(x = 남편, y = 아내)는 시작하자마자 알 수 있고, `verdict_shown`은 판결 뒤에 `true`가 됩니다.
- `skip_reveal()`: 이 화면에서만 바로 판결로 넘어갑니다. 플레이어는 Space·Enter·클릭으로 건너뛸 수 있는데, 경기 막판 연타가 넘어오지 않도록 시작 후 1초(`SKIP_GRACE_MSEC`)는 무시합니다.
- `play(outcome)`: `Outcome.WIFE_WINS`, `HUSBAND_WINS`, `DRAW` 중 하나를 바로 재생합니다.
- `outcome_for(husband_gold, wife_gold)`: 정적 판정 함수. 같으면 `DRAW`.
- 승자는 `celebrate_jump`, 패자는 `defeat_kneel`(각 6초, 1회 재생 후 마지막 자세 유지). 무승부는 두 사람 모두 시작 자세로 서 있습니다.
- 3D 무대는 `own_world_3d` SubViewport 안에 있어 집과 아이템이 겹쳐 보이지 않습니다.
- 정점색 보정: 얼굴의 원본 `COLOR_0`를 읽는 전용 `ShaderMaterial`을 인스턴스별로 적용합니다. glTF의 선형 색을 Compatibility 출력에서만 sRGB로 변환하고, Forward+/Mobile에서는 선형 색을 유지합니다. 표면 거칠기와 반사 값도 가져오며 원본 임포트 재질·공유 메시·웨이트는 바꾸지 않습니다. `vertex_color_is_srgb`가 Compatibility에 적용되지 않는 점은 [Godot 재질 문서](https://docs.godotengine.org/en/stable/classes/class_basematerial3d.html#class-basematerial3d-property-vertex-color-is-srgb)를 참고하세요.
- Blender의 Noise/ColorRamp가 연결된 벽·바닥·머리카락은 원본 diffuse 색을 GLB의 기본 색으로 복원했습니다. 메시·관절·정점색·모션 바이너리는 그대로입니다. 실내 보조 조명과 SubViewport 4× MSAA로 캐릭터와 링을 표시합니다.

단독 확인: 에디터에서 장면을 열고 F6. `preview_rows()`의 샘플 가방(저금통, 가짜 반지, 불륜 편지 포함)으로 정산 연출 전체가 재생됩니다.

## 정산 연출 (`settlement_reveal.gd`)

1. 개정: "재산 분할 심리를 시작합니다". 왼쪽 WIFE, 오른쪽 HUSBAND 카드가 나타나고, 가방 아이콘은 검은 실루엣으로 보입니다.
2. 일반 물건: 양쪽 가방에서 싼 물건부터 한 쌍씩 아이콘이 튀어나오며 색이 돌아오고, `+금액`이 떠오르며 카운터가 빠르게 올라갑니다. 간격은 0.42초에서 0.14초까지 빨라지고, 500 G 이상이면 잠깐 멈추고 초상화가 자랑하는 표정을 짓습니다.
3. 특수 증거물: 저금통 → 반지 → 편지 순서로 하나씩 가운데 카드가 뜹니다. 카드에는 상황 설명(타자 효과), 판정 도장, 반영 금액이 나오고, 카드가 닫히면서 카운터에 반영됩니다.
   - 저금통: 흔들리다 깨지고 숫자가 돌다 멈춤. 0~600 G(10 G 단위). 0이면 "텅 비었다!"
   - 반지: "감정 중…" 뒤 진품(800 G) 또는 가짜(30%, 50 G로 깎이고 아이콘이 회색이 됨)
   - 편지: 연애편지(150 G) 또는 불륜 증거(50%, 150 G에 더해 상대에게서 위자료 최대 500 G를 동전이 날아오며 옮김. 상대가 그 시점에 가진 금액이 상한)
4. 판결: 차이가 10% 이내면 드럼롤 뒤에 의사봉 소리, 화면 번쩍임과 흔들림. 승자 카드가 커지고 금액이 노랗게, 패자 카드는 어두워지며 승패 모션이 재생됩니다.

결과 문구와 이름·금액은 HUD의 "WIFE" 배지처럼 IntelOneMono에 두꺼운 검은 외곽선과 그림자를 씁니다(`badge_style`). 한글은 같은 외곽선에 기본 폰트를 씁니다.

## 게임 연결

- 플레이어 0 = 호스트 = 남편(03_Young), 플레이어 1 = 게스트 = 아내(02_Woman). 혼자 테스트의 더미는 플레이어 1(아내 칸)입니다. HUD 가방·지갑·획득 로그도 같은 순서로 맞췄습니다.
- `courtyard.gd`의 `bag_gold()`는 가방 속 `gold_value`의 액면 합계입니다(경기 중 표시용). 판결은 `settlement()`가 만든 정산 목록의 합계 `final_gold`로 정합니다.
- 정산 목록(`settlement.gd`)은 가방 물건마다 `[플레이어, 아이템 번호, 인정 금액, 효과, 상대에게서 가져온 금액]` 다섯 칸입니다. 저금통 금액, 반지 진위, 편지 결과는 호스트의 `settlement_rng`로 한 번만 정합니다.
- LAN에서는 호스트만 타이머를 돌리고, 시간 종료 때 이 목록을 `_end_round` RPC로 두 화면에 보냅니다. 게스트는 `is_valid()`로 검사한 뒤 같은 목록을 재생하므로 숫자와 판결이 항상 같습니다. 건너뛰기는 각 화면에서만 적용됩니다.
- 튜토리얼은 `settlement_surprises = false`로 반지를 진품, 편지를 연애편지로 고정해 정해진 역전승이 뒤집히지 않게 하고, `verdict_shown` 뒤에 완료 화면으로 넘어갑니다.
- `_end_round`는 집 장면을 `PROCESS_MODE_DISABLED`로 멈추고, 결말 노드는 `PROCESS_MODE_ALWAYS`로 붙여 애니메이션이 계속 재생됩니다. R(테스트 재시작)과 Esc(나가기)는 그대로 동작합니다.

## 검사

```
godot --headless --path . --script res://tests/ending_smoke.gd
godot --headless --path . --script res://tests/settlement_smoke.gd
```

`settlement_smoke`는 정산 순서, 액면 고정, 300개 시드에서의 금액 범위·위자료 상한·합계 일치, 같은 시드의 재현성, 잘못된 목록 거부를 확인합니다. `ending_smoke`는 샘플 가방 전체 연출(5배속: 단계 순서, 카드 3장, 위자료 이동, 최종 카운터와 결과 문구), 카드가 열린 중간에 건너뛰기, 1초 유예, 판정 3종, 두 승리 모션의 클립·6초 종료·마지막 자세 유지, 혼자 테스트(1인)·더미·무승부 라운드, 멈춘 라운드 위에서의 재생, R/Esc를 확인합니다. 연출 도중 R 재시작도 확인합니다. `tests/lan_smoke.gd`는 두 화면이 같은 정산 합계와 호스트 판정(남편 20 G 승리)을 보이는지 확인합니다.
