# 법정 결말 모션

라운드가 끝나면 가방 금액으로 승패를 정하고 법정 링에서 결과 모션을 재생합니다. 영상이나 이미지 카드가 아니라 `assets/endings`의 GLB 관절 애니메이션입니다(배치·카메라 값은 `ending_assets_manifest.json`).

## 장면과 API

`res://courtroom_ending.tscn` (`courtroom_ending.gd`, CanvasLayer)

- `show_scores(husband_gold, wife_gold) -> Outcome`: 금액으로 결과를 정해 재생하고 금액을 표시합니다.
- `play(outcome)`: `Outcome.WIFE_WINS`, `HUSBAND_WINS`, `DRAW` 중 하나를 바로 재생합니다.
- `outcome_for(husband_gold, wife_gold)`: 정적 판정 함수. 같으면 `DRAW`.
- 승자는 `celebrate_jump`, 패자는 `defeat_kneel`(각 6초, 1회 재생 후 마지막 자세 유지). 무승부는 두 사람 모두 시작 자세로 서 있습니다.
- 3D 무대는 `own_world_3d` SubViewport 안에 있어 집과 아이템이 겹쳐 보이지 않습니다.
- 정점색 보정: 얼굴의 원본 `COLOR_0`를 읽는 전용 `ShaderMaterial`을 인스턴스별로 적용합니다. glTF의 선형 색을 Compatibility 출력에서만 sRGB로 변환하고, Forward+/Mobile에서는 선형 색을 유지합니다. 표면 거칠기와 반사 값도 가져오며 원본 임포트 재질·공유 메시·웨이트는 바꾸지 않습니다. `vertex_color_is_srgb`가 Compatibility에 적용되지 않는 점은 [Godot 재질 문서](https://docs.godotengine.org/en/stable/classes/class_basematerial3d.html#class-basematerial3d-property-vertex-color-is-srgb)를 참고하세요.
- Blender의 Noise/ColorRamp가 연결된 벽·바닥·머리카락은 원본 diffuse 색을 GLB의 기본 색으로 복원했습니다. 메시·관절·정점색·모션 바이너리는 그대로입니다. 실내 보조 조명과 SubViewport 4× MSAA로 캐릭터와 링을 표시합니다.

단독 확인: 에디터에서 장면을 열고 F6. 인스펙터의 `preview_outcome`으로 결과를 고릅니다.

## 게임 연결

- 플레이어 0 = 호스트 = 남편(03_Young), 플레이어 1 = 게스트 = 아내(02_Woman). 혼자 테스트의 더미는 플레이어 1(아내 칸)입니다. HUD 가방·지갑·획득 로그도 같은 순서로 맞췄습니다.
- `courtyard.gd`의 `bag_gold()`가 가방에 들어간 아이템의 `gold_value`를 더합니다. HUD 숫자 애니메이션 값은 쓰지 않습니다.
- LAN에서는 호스트만 타이머를 돌리고, 시간 종료 때 호스트가 계산한 금액을 `_end_round` RPC로 두 화면에 보냅니다. 게스트는 받은 값만 표시합니다.
- `_end_round`는 집 장면을 `PROCESS_MODE_DISABLED`로 멈추고, 결말 노드는 `PROCESS_MODE_ALWAYS`로 붙여 애니메이션이 계속 재생됩니다. R(테스트 재시작)과 Esc(나가기)는 그대로 동작합니다.

## 검사

```
godot --headless --path . --script res://tests/ending_smoke.gd
```

판정 3종, 두 승리 모션의 클립·6초 종료·마지막 자세 유지, 혼자 테스트(1인)·더미·무승부 라운드, 멈춘 라운드 위에서의 재생, R/Esc를 확인합니다. `tests/lan_smoke.gd`는 두 화면이 같은 호스트 판정(남편 20 G 승리)을 보이는지 확인합니다.
