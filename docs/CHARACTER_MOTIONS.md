# 캐릭터 모션 연결

게임 캐릭터는 `assets/characters/motions/`의 GLB 3개를 쓴다. 각 GLB는 캐릭터별 단일 skeleton(노년·청년 35 bones, 여성 65 bones)이고, 소품 메시나 두 번째 리그가 없다. 내보낸 GLB에서만 목·쇄골이 스케일 분리(scale-isolated) 계층으로 되어 있다. 관절 이름과 뼈 길이는 원본 그대로이고, 원본 .blend는 바뀌지 않았다. 클립 길이·원본 프레임·루프 여부·접점 뼈·줄다리기 궤적은 `CHARACTER_MOTIONS_MANIFEST.json`에 있다. 예전 `assets/characters/thump/` GLB는 지우지 않았지만 게임에서는 더 이상 쓰지 않는다.

| 역할 | 파일 | 배정 위치 |
| --- | --- | --- |
| 플레이어(호스트) 청년 | `03_Young.glb` | `player.gd` `DEFAULT_MODEL` |
| 게스트 여성 | `02_Woman.glb` | `courtyard.gd` `GUEST_MODEL` |
| 테스트 더미 노년 | `01_Elder.glb` | `test_mode.gd` `TARGET_MODEL` |

모델은 GLB에서 +Z를 보고 player는 -Z를 보므로 `Model`은 y축으로 PI 회전하고 0.45배로 줄인다.

## 상태 전환 (`player.gd`)

`_update_motion()`이 매 물리 프레임 아래 순서로 하나만 고른다. 현재 클립(접두사 제외)은 `player.motion`에 있다.

바나나 껍질을 밟은 동안에는 아래 상태보다 넘어짐을 먼저 처리한다. 제자리에서 시각 모델만 뒤로 넘어지고 남은 스턴이 끝나기 전에 일어난다. 그동안 조준·줍기·투척·가방 넣기는 차단하며, 손 접점은 계속 갱신한다. 기존 스턴이 2초보다 길면 넘어짐도 그 시간에 맞춰 유지된다.

1. **Tug_Fast / Tug_Slow**: 쟁탈전 중. `contest_presentation.gd`가 공유 phase로 seek한다.
2. **Grab**: 유효한 잡기 진행 비율(`_grab_elapsed / packing_seconds`)로 seek, 끝 포즈 유지. 버튼 해제·거리 이탈·포커스 이탈·피격/스턴·쟁탈전 시작에 풀린다.
3. **Aim**: 들고 조준 중. 1.2초짜리 준비 동작(원본 1~38프레임)을 2.5배속으로 재생해 0.48초 뒤 준비 자세가 되고, 그 자세를 유지한다. 마지막 프레임은 Throw 0프레임의 손 접점과 같다. 물리 차지 게이지(2초 주기)와 입력 타이밍은 그대로다. 스턴은 Aim 클립만 끊는다. 원래 게임처럼 차지 상태(`_is_aiming`)와 타이머는 남아 있어서, 버튼을 계속 누르고 있으면 스턴 후 Aim이 처음부터 다시 재생되고 차지가 이어진다.
4. **Pickup / Throw**(일회성): 끝날 때까지 유지, 스턴이 끊는다.
   - Pickup: 소유 확정(`hold_pickup`) 때 0초부터 2배속(약 0.97초).
   - Throw: 실제 launch가 승인된 순간(`release_pickup(true)` 통과) 0초(릴리스 포즈)부터 1.5배속.
   - 일반 놓기·스냅샷 소유 변경·가방 넣기·쟁탈전 전환·막힌 투척은 Throw를 재생하지 않는다.
5. **RunCarry / Run**: 이동 중. 재생 속도 = 지면 속도 / (0.9 m/s × 0.45), 최대 4배(1 m/s에서 약 2.47배).
6. **Carry / Idle**: 멈춤. 아무것도 들지 않으면 크게 호흡하는 Idle이 기본이다.

## 접점과 물리

- `HandSocket`은 `socket_pickup_object` 뼈 위치를 따라간다(방향·크기는 player 기준 유지). 예전 0.47 m 고정 높이는 없앴다. 휴대 중에는 물건 아래쪽이 바닥에서 0.021 m 떨어질 만큼만 보호한다. 15 cm 발사 여유 높이는 실제 발사 원점에만 더하므로, 줍기 초반에 물건이 손 위로 뜨지 않는다. 큰 물건과 낮아진 발사 원점의 충돌 보호는 유지한다.
- Aim·Throw 동안 보이는 물건은 실제 던지는 손 `socket_throw_ball.R`을 따라간다(위치만, 같은 바닥 보호). Carry 접점에서 0.1초 동안 블렌드한다.
- 물리 발사 원점은 manifest의 `release_anchor_model_local` 하나다. 캐릭터별로 Throw 릴리스 프레임(= Aim 마지막 프레임)의 실제 손 접점을 Godot 모델 좌표로 적은 값이다. `_throw_transform()`은 지금 재생 중인 포즈와 상관없이(예: 서버에서 본 원격 플레이어가 아직 Pickup 중이어도) 호스트·게스트 모두 이 점에서 발사한다. 준비 자세가 되면(0.48초) 손에 든 물건이 정확히 이 점에 있다. 그보다 일찍 놓으면 물건은 손에서 이 점으로 옮겨져 발사된다. 궤적 미리보기도 같은 점에서 시작한다. 충돌 차단, 0~10 차지 속도, 25도, 15 cm 낮춘 발사 원점 판정은 바뀌지 않았다.
- AnimationPlayer는 수동 모드다. `_update_animation`에서 포즈를 먼저 진행한 뒤 소켓을 읽으므로, 빠른 와인드업에서도 물건이 손을 한 프레임 늦게 따라가지 않는다.
- `hold_pickup`은 Pickup 첫 프레임(접촉 포즈)에 소켓을 즉시 맞춘다.

## 줄다리기 (`contest_presentation.gd`)

- `pickup_contest.gd`의 실제 시작/결과/취소(호스트·게스트 모두 라운드 ID·revision으로 검증된 경로)에서 시작·종료된다.
- 두 캐릭터의 `Model`만 원래 배치 간격 2.4(× 0.45 = 1.08 m)로 대상 물건 양쪽에 서서 서로(물건 쪽)를 본다. CharacterBody는 움직이지 않는다. 종료·취소 때 `Model` transform을 원래 값으로 되돌린다.
- player 0이 side 0(-축), player 1이 side 1. 클립이 다른 side용으로 만들어졌으면 같은 phase를 반 주기 늦춰 재생한다(예: 노년 더미가 side 1일 때).
- 공유 phase(`tug_phase`, 0~1) 하나로 두 캐릭터와 물건을 움직인다. 템포를 바꿔도 phase는 그대로다.
- 호스트의 phase·템포가 기준이다. 호스트는 0.25초마다 `_sync_tug(round_id, item, revision, phase, fast)`(unreliable_ordered)를 보내고, 게스트는 라운드·물건·revision이 모두 맞을 때만 이 값으로 맞춘다. 패킷 사이에는 로컬로 진행한다. 끝났거나 취소된 라운드의 패킷은 줄다리기를 다시 시작하지 않고 물건도 움직이지 않는다.
- 템포: `tug_tempo = &"auto"`(0.6초 안에 누름이 있으면 Fast, 없으면 Slow), `&"fast"`, `&"slow"`.
- 실제 공유 물건이 manifest의 `tug_controller_paths`(player 0 캐릭터의 궤적 하나) x·y를 따라간다. 스테이지 z의 수 mm 흔들림은 쓰지 않는다. 취소하면 물건은 시작 때 위치로 돌아가고, 승자는 그대로 물건을 든다(Pickup).
- 팔·뼈는 늘리지 않는다. 큰 물건은 손바닥 사이 간격에 맞지 않을 수 있다.

## LAN

- 잡기: 서버의 `pickup_contest._set_grab_item()`이 상태를 바꿀 때마다 신뢰 RPC `_sync_grab(round_id, player, item)`을 보낸다. 받는 쪽은 자기가 조종하지 않는 캐릭터에만 Grab을 재생한다. 소유권은 바꾸지 않는다. 끝 이벤트가 빠져도 `packing_seconds + 1초` 뒤 스스로 멈춘다.
- 투척: 서버에서 실제 launch가 승인되면 `pickup_launched` → `courtyard._broadcast_throw()`가 `_ownership_revision`을 올리고 `_apply_throw(player, item, revision)`을 보낸다. 게스트는 더 새 revision일 때만 손을 비우고 Throw를 한 번 재생한다. revision이 올라갔으므로 그 전 스냅샷은 놓은 물건을 다시 붙일 수 없다. 스냅샷으로 추론한 `release_pickup(false)`는 Throw가 아니다.
- 원격 플레이어의 조준(Aim)은 서버가 알지 못하므로 보이지 않는다. 발사 원점은 고정 릴리스 기준점이라 양쪽이 같다.

## 임포트 시 전환 키 유지

세 GLB의 `.glb.import` 파일에서 `animation/remove_immutable_tracks=false`를 유지한다. 각 클립에는 뼈마다 위치·회전·스케일의 상수 초기화 키도 포함돼 있다. 이 키를 지우면 호흡 최대 자세에서 달리기·투척으로 전환할 때 이전 가슴 크기나 머리카락 위치가 남는다. `.glb.import`도 GLB와 함께 버전 관리한다. `character_motion_smoke`는 실제 임포트된 각 클립을 최대 들숨 뒤에 재생하고 처음 재생한 결과와 모든 뼈 행렬이 같은지 검사한다.

## 색

`COLOR_0`가 있는 표면(얼굴)에만 인스턴스별로 `painted_vertex_color.gdshader` override를 건다. 나머지 표면은 GLB 재질 색을 그대로 쓰고, 피격 깜빡임은 `material_overlay`로 따로 유지된다.

## 검사

```
Godot_v4.7.2-stable_win64_console.exe --headless --path . -s res://tests/character_motion_smoke.gd
```

클립 10개 × 캐릭터 3명의 관절이 실제로 움직이는지(Carry는 Idle과 다른 고정 포즈인지), Aim 끝 = Throw 시작 손 접점 = manifest 릴리스 기준점인지, 조준 중 물건이 실제 던지는 손에 있는지, 예측 원점 = 실제 발사 원점인지, 상태 전환, 잡기 취소, 차지/막힌 투척/일반 놓기, 쟁탈전 phase·템포·서버 phase 보정·오래된 패킷 거부·종료·취소, 원격 Grab/Throw 이벤트와 오래된 스냅샷을 검사한다. LAN 쪽은 `lan_smoke.gd`, `contest_lan_smoke.gd`에 원격 Grab·Throw·줄다리기와 게스트 phase 보정 검사를 더했다. `pickup_smoke.gd`는 손에서 놓은 공이 멈출 때까지(속도 < 0.10이 10프레임, 최대 600프레임, 초과하면 실패) 기다린 뒤 회수한다.
