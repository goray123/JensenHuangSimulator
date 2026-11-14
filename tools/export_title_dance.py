"""Bake the v14 party dance (Dance_Bunny_Party) plus the breathing Idle of Elder and Woman into title-screen GLBs.
The title blends the two so the dance reads calmer.
Same bake as AI Designer's export_character_motions.py: constraints evaluated, neck/clavicles under root.
Usage: blender -b --python tools/export_title_dance.py -- <Elder_Woman_Dance_v14.blend> <out_dir>
The source .blend is read only (its hash is checked before and after).
"""
import bpy, sys, json, math, hashlib, struct
from pathlib import Path

ARGS = sys.argv[sys.argv.index('--') + 1:]
SOURCE = Path(ARGS[0])
OUT = Path(ARGS[1])
OUT.mkdir(parents=True, exist_ok=True)
NAMES = ['01_Elder', '02_Woman']
# label -> (source action, first, last). Dance keys 1-97 with 97 == 1: one seamless 3.2 s loop at 30 fps.
# Idle matches the game's Idle clip (Idle_Breathe 1-121, 4 s).
CLIPS = {'Dance': ('Dance_Bunny_Party', 1, 97), 'Idle': ('Idle_Breathe', 1, 121)}
FPS = 30
SHA = hashlib.sha256(SOURCE.read_bytes()).hexdigest()


def assign(o, a):
    o.animation_data_create()
    o.animation_data.action = a
    o.animation_data.action_slot = a.slots[0]


def frame(s, f):
    s.frame_set(math.floor(f), subframe=f - math.floor(f))
    bpy.context.view_layer.update()


def snapshot(r):
    return {p.name: p.matrix.copy() for p in r.pose.bones}


def pose_global(r, bn, M, K):
    b = r.data.bones[bn]
    if b.parent:
        B = b.convert_local_to_pose(M, b.matrix_local, parent_matrix=K[b.parent.name],
                                    parent_matrix_local=b.parent.matrix_local, invert=True)
    else:
        B = b.matrix_local.inverted() @ M
    r.pose.bones[bn].matrix_basis = B


def glb(path):
    data = path.read_bytes()
    length, kind = struct.unpack_from('<II', data, 12)
    assert kind == 0x4E4F534A
    return data, json.loads(data[20:20 + length]), data[20 + length:]


def repair_materials(path, palette):
    data, doc, binary = glb(path)
    for m in doc.get('materials', []):
        src = palette.get(m.get('name'))
        if src and src['linked'] and not src['vertex']:
            m.setdefault('pbrMetallicRoughness', {})['baseColorFactor'] = src['diffuse']
    encoded = json.dumps(doc, separators=(',', ':'), ensure_ascii=True).encode()
    encoded += b' ' * ((-len(encoded)) % 4)
    path.write_bytes(struct.pack('<4sII', b'glTF', 2, 20 + len(encoded) + len(binary))
                     + struct.pack('<II', len(encoded), 0x4E4F534A) + encoded + binary)


report = {}
for n in NAMES:
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE))
    S = bpy.context.scene
    S.render.fps = FPS
    for name in ['01_Elder', '02_Woman', '03_Young']:
        bpy.data.collections[name].hide_viewport = False
        root = bpy.data.objects[name + ' | pose root']
        root.animation_data_clear()
        root.location = (0, 0, 0)
        root.rotation_euler = (0, 0, 0)
        root.scale = (1, 1, 1)
    r = bpy.data.objects[n + '_Run_Rig']
    captured = {}
    for label, (action, first, last) in CLIPS.items():
        assign(r, bpy.data.actions[n + '__' + action])
        captured[label] = []
        for f in range(first, last + 1):
            frame(S, f)
            captured[label].append(snapshot(r))
    for p in r.pose.bones:
        for c in list(p.constraints):
            p.constraints.remove(c)
    # glTF has no inherit_scale=NONE; keep those branches under root exactly like the game export.
    bpy.ops.object.select_all(action='DESELECT')
    r.select_set(True)
    bpy.context.view_layer.objects.active = r
    bpy.ops.object.mode_set(mode='EDIT')
    for bn in ['neck', 'clavicle.L', 'clavicle.R']:
        b = r.data.edit_bones[bn]
        b.use_connect = False
        b.parent = r.data.edit_bones['root']
    bpy.ops.object.mode_set(mode='OBJECT')
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)
    errors = {}
    seams = {}
    for label, rows in captured.items():
        a = bpy.data.actions.new(n + '__' + label)
        a.use_fake_user = True
        r.animation_data_create()
        r.animation_data.action = a
        r.animation_data.action_slot = a.slots.new('OBJECT', r.name)
        a.use_frame_range = True
        a.frame_start = 0
        a.frame_end = len(rows) - 1
        prev = {}
        max_error = 0.0
        for i, K in enumerate(rows):
            S.frame_set(i)
            for p in r.pose.bones:
                pose_global(r, p.name, K[p.name], K)
                if p.name in prev and p.rotation_quaternion.dot(prev[p.name]) < 0:
                    p.rotation_quaternion.negate()
                prev[p.name] = p.rotation_quaternion.copy()
                for prop in ['location', 'rotation_quaternion', 'scale']:
                    p.keyframe_insert(prop, frame=i, group=p.name)
            bpy.context.view_layer.update()
            max_error = max(max_error, max(max(abs(r.pose.bones[b].matrix[j][k] - M[j][k])
                                               for j in range(4) for k in range(4)) for b, M in K.items()))
        for layer in a.layers:
            for st in layer.strips:
                for bag in st.channelbags:
                    for fc in bag.fcurves:
                        for key in fc.keyframe_points:
                            key.interpolation = 'LINEAR'
        assert max_error < 0.0003, (n, label, max_error)
        errors[label] = max_error
        seams[label] = max(max(abs(rows[0][b][j][k] - rows[-1][b][j][k]) for j in range(4) for k in range(4)) for b in rows[0])
    col = bpy.data.collections[n]
    for other in list(bpy.data.scenes):
        if other != S:
            bpy.data.scenes.remove(other)
    if col.name not in S.collection.children:
        S.collection.children.link(col)
    for child in list(S.collection.children):
        if child != col:
            S.collection.children.unlink(child)
    palette = {}
    for m in bpy.data.materials:
        bs = next((nd for nd in m.node_tree.nodes if nd.type == 'BSDF_PRINCIPLED'), None) if m.use_nodes else None
        if bs:
            base = bs.inputs['Base Color']
            palette[m.name] = {'diffuse': list(m.diffuse_color), 'linked': base.is_linked,
                               'vertex': any(l.from_node.type == 'VERTEX_COLOR' for l in base.links)}
    S.frame_start = 0
    S.frame_end = len(captured['Dance']) - 1
    assign(r, bpy.data.actions[n + '__Dance'])
    frame(S, 0)
    bpy.ops.object.select_all(action='DESELECT')
    for o in col.objects:
        o.hide_set(False)
        o.select_set(True)
    bpy.context.view_layer.objects.active = r
    path = OUT / (n + '_Dance.glb')
    bpy.ops.export_scene.gltf(filepath=str(path), export_format='GLB', use_selection=True, export_cameras=False,
                              export_lights=False, export_animations=True, export_animation_mode='ACTIONS',
                              export_bake_animation=True, export_vertex_color='MATERIAL',
                              export_all_vertex_colors=True, export_yup=True)
    repair_materials(path, palette)
    data, doc, _ = glb(path)
    anims = {an['name']: max(doc['accessors'][sp['input']]['max'][0] for sp in an['samplers'])
             for an in doc.get('animations', [])}
    assert len(doc.get('skins', [])) == 1 and set(anims) == {n + '__' + c for c in CLIPS}, anims
    for label, (_, first, last) in CLIPS.items():
        assert abs(anims[n + '__' + label] - (last - first) / FPS) < 0.002, anims
    assert not any(o.get('name', '').startswith(('CTRL_Tug_Item', 'ATTACH_Future_Object')) for o in doc.get('nodes', []))
    report[n] = {'file': path.name, 'bytes': len(data), 'clips': anims,
                 'bake_error': errors, 'loop_seam_error': seams}
    print('TITLE_DANCE_EXPORTED', n, json.dumps(report[n]), flush=True)

assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == SHA
report.update({'source_blend': SOURCE.name, 'source_sha256': SHA, 'fps': FPS, 'loop': True,
               'clips': {label: {'source': src, 'source_frames': [a, b]} for label, (src, a, b) in CLIPS.items()}})
(OUT / 'TITLE_DANCE_MANIFEST.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print('TITLE_DANCE_EXPORT_COMPLETE', flush=True)
