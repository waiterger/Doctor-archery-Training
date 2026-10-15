shader_type canvas_item;

// 受击闪白：把最终颜色按 flash 强度混到纯白。
// 用 shader 而不是改 color 属性 → 和「燃烧橙 / 冰冻蓝」的状态色互不干扰。
uniform float flash : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	COLOR.rgb = mix(COLOR.rgb, vec3(1.0), flash);
}