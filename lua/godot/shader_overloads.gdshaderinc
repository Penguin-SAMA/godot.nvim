// Supplemental declarations for gdshader-lsp v0.3.2, from Godot 4.7.2's
// ShaderLanguage::builtin_func_defs. Only the language server includes this file.

vec2 mod(vec2 x, float y);
vec3 mod(vec3 x, float y);
vec4 mod(vec4 x, float y);

vec2 min(vec2 a, float b);
vec3 min(vec3 a, float b);
vec4 min(vec4 a, float b);
ivec2 min(ivec2 a, int b);
ivec3 min(ivec3 a, int b);
ivec4 min(ivec4 a, int b);
uvec2 min(uvec2 a, uint b);
uvec3 min(uvec3 a, uint b);
uvec4 min(uvec4 a, uint b);

vec2 max(vec2 a, float b);
vec3 max(vec3 a, float b);
vec4 max(vec4 a, float b);
ivec2 max(ivec2 a, int b);
ivec3 max(ivec3 a, int b);
ivec4 max(ivec4 a, int b);
uvec2 max(uvec2 a, uint b);
uvec3 max(uvec3 a, uint b);
uvec4 max(uvec4 a, uint b);

vec2 clamp(vec2 x, float minVal, float maxVal);
vec3 clamp(vec3 x, float minVal, float maxVal);
vec4 clamp(vec4 x, float minVal, float maxVal);
ivec2 clamp(ivec2 x, int minVal, int maxVal);
ivec3 clamp(ivec3 x, int minVal, int maxVal);
ivec4 clamp(ivec4 x, int minVal, int maxVal);
uvec2 clamp(uvec2 x, uint minVal, uint maxVal);
uvec3 clamp(uvec3 x, uint minVal, uint maxVal);
uvec4 clamp(uvec4 x, uint minVal, uint maxVal);

vec2 mix(vec2 a, vec2 b, float value);
vec2 mix(vec2 a, vec2 b, bvec2 value);
vec3 mix(vec3 a, vec3 b, float value);
vec3 mix(vec3 a, vec3 b, bvec3 value);
vec4 mix(vec4 a, vec4 b, float value);
vec4 mix(vec4 a, vec4 b, bvec4 value);

vec2 step(float edge, vec2 x);
vec3 step(float edge, vec3 x);
vec4 step(float edge, vec4 x);

vec2 smoothstep(vec2 edge0, vec2 edge1, vec2 value);
vec3 smoothstep(vec3 edge0, vec3 edge1, vec3 value);
vec4 smoothstep(vec4 edge0, vec4 edge1, vec4 value);

vec2 reflect(vec2 I, vec2 N);
vec4 reflect(vec4 I, vec4 N);

vec2 refract(vec2 I, vec2 N, float eta);
vec4 refract(vec4 I, vec4 N, float eta);

vec2 faceforward(vec2 N, vec2 I, vec2 Nref);
vec3 faceforward(vec3 N, vec3 I, vec3 Nref);
vec4 faceforward(vec4 N, vec4 I, vec4 Nref);

bvec2 lessThan(ivec2 a, ivec2 b);
bvec3 lessThan(ivec3 a, ivec3 b);
bvec4 lessThan(ivec4 a, ivec4 b);
bvec3 lessThan(uvec3 a, uvec3 b);
bvec4 lessThan(uvec4 a, uvec4 b);
bvec2 lessThan(uvec2 a, uvec2 b);

bvec2 greaterThan(ivec2 a, ivec2 b);
bvec3 greaterThan(ivec3 a, ivec3 b);
bvec4 greaterThan(ivec4 a, ivec4 b);
bvec2 greaterThan(uvec2 a, uvec2 b);
bvec3 greaterThan(uvec3 a, uvec3 b);
bvec4 greaterThan(uvec4 a, uvec4 b);

bvec2 lessThanEqual(ivec2 a, ivec2 b);
bvec3 lessThanEqual(ivec3 a, ivec3 b);
bvec4 lessThanEqual(ivec4 a, ivec4 b);
bvec2 lessThanEqual(uvec2 a, uvec2 b);
bvec3 lessThanEqual(uvec3 a, uvec3 b);
bvec4 lessThanEqual(uvec4 a, uvec4 b);

bvec2 greaterThanEqual(vec2 a, vec2 b);
bvec3 greaterThanEqual(vec3 a, vec3 b);
bvec4 greaterThanEqual(vec4 a, vec4 b);
bvec2 greaterThanEqual(ivec2 a, ivec2 b);
bvec3 greaterThanEqual(ivec3 a, ivec3 b);
bvec4 greaterThanEqual(ivec4 a, ivec4 b);
bvec2 greaterThanEqual(uvec2 a, uvec2 b);
bvec3 greaterThanEqual(uvec3 a, uvec3 b);
bvec4 greaterThanEqual(uvec4 a, uvec4 b);

bvec2 equal(ivec2 a, ivec2 b);
bvec3 equal(ivec3 a, ivec3 b);
bvec4 equal(ivec4 a, ivec4 b);
bvec2 equal(uvec2 a, uvec2 b);
bvec3 equal(uvec3 a, uvec3 b);
bvec4 equal(uvec4 a, uvec4 b);
bvec2 equal(bvec2 a, bvec2 b);
bvec3 equal(bvec3 a, bvec3 b);
bvec4 equal(bvec4 a, bvec4 b);

bvec2 notEqual(ivec2 a, ivec2 b);
bvec3 notEqual(ivec3 a, ivec3 b);
bvec4 notEqual(ivec4 a, ivec4 b);
bvec2 notEqual(uvec2 a, uvec2 b);
bvec3 notEqual(uvec3 a, uvec3 b);
bvec4 notEqual(uvec4 a, uvec4 b);
bvec2 notEqual(bvec2 a, bvec2 b);
bvec3 notEqual(bvec3 a, bvec3 b);
bvec4 notEqual(bvec4 a, bvec4 b);

vec4 textureGrad(sampler2D sampler, vec2 coords, vec2 dPdx, vec2 dPdy);
ivec4 textureGrad(isampler2D sampler, vec2 coords, vec2 dPdx, vec2 dPdy);
uvec4 textureGrad(usampler2D sampler, vec2 coords, vec2 dPdx, vec2 dPdy);
vec4 textureGrad(sampler2DArray sampler, vec3 coords, vec2 dPdx, vec2 dPdy);
ivec4 textureGrad(isampler2DArray sampler, vec3 coords, vec2 dPdx, vec2 dPdy);
uvec4 textureGrad(usampler2DArray sampler, vec3 coords, vec2 dPdx, vec2 dPdy);
vec4 textureGrad(sampler3D sampler, vec3 coords, vec3 dPdx, vec3 dPdy);
ivec4 textureGrad(isampler3D sampler, vec3 coords, vec3 dPdx, vec3 dPdy);
uvec4 textureGrad(usampler3D sampler, vec3 coords, vec3 dPdx, vec3 dPdy);
vec4 textureGrad(samplerCube sampler, vec3 coords, vec3 dPdx, vec3 dPdy);
vec4 textureGrad(samplerCubeArray sampler, vec4 coords, vec3 dPdx, vec3 dPdy);

vec4 textureProj(sampler3D sampler, vec4 coords);
vec4 textureProj(sampler3D sampler, vec4 coords, float bias);
ivec4 textureProj(isampler3D sampler, vec4 coords);
ivec4 textureProj(isampler3D sampler, vec4 coords, float bias);
uvec4 textureProj(usampler3D sampler, vec4 coords);
uvec4 textureProj(usampler3D sampler, vec4 coords, float bias);

vec4 texture(samplerCube sampler, vec3 coords);
vec4 texture(samplerCubeArray sampler, vec4 coords);
