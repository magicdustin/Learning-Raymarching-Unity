﻿Shader "Raymarch/RaymarchShader"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        // No culling or depth
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
			#pragma target 3.0

            #include "UnityCG.cginc"
			#include "DistanceFunctions.cginc"

			sampler2D _MainTex;
			uniform sampler2D _CameraDepthTexture;
			uniform float4x4 _CamFrustum, _CamToWorld;
			uniform int _MaxIterations;
			uniform float _Accuracy;
			uniform float _maxDistance, _box1Round, _boxSphereSmooth, _sphereIntersectSmooth;
			uniform float _ShadowIntensity, _ShadowPenumbra;
			uniform float2 _ShadowDistance;
			uniform float3 _modInterval;
			uniform float3 _lightDir, _LightCol;
			uniform float4 _sphere1, _sphere2, _box1;
			uniform float _LightIntensity;
			uniform fixed4 _mainColor;


            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
				float3 ray : TEXCOORD1;
            };

            v2f vert (appdata v)
            {
                v2f o;
				half index = v.vertex.z;
				v.vertex.z = 0;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;

				o.ray = _CamFrustum[(int)index].xyz;

				o.ray /= abs(o.ray.z);

				o.ray = mul(_CamToWorld, o.ray);
                return o;
            }

			float BoxSphere(float3 p) {
				float sphere1 = sdSphere(p - _sphere1.xyz, _sphere1.w);
				float box1 = sdRoundBox(p - _box1.xyz, _box1.www, _box1Round);
				float combined1 = opSS(sphere1, box1, _boxSphereSmooth);
				float sphere2 = sdSphere(p - _sphere2.xyz, _sphere2.w);
				float combined2 = opIS(sphere2, combined1, _sphereIntersectSmooth);
				return combined2;
			}

			float distanceField(float3 p) 
			{
				//float modX = pMod1(p.x, _modInterval.x);
				//float modY = pMod1(p.y, _modInterval.y);
				//float modZ = pMod1(p.z, _modInterval.z);
				//float triang1 = DE(p - float3(0, 0, 0), 2, 50, 100.0);
				//float thing1 = DEM(p - float3(0, 0, 0), 20, 2, _SinTime.x * 40);

				float ground = sdPlane(p, float4(0, 1, 0, 0));
				float boxSphere1 = BoxSphere(p);

				return opU(ground, boxSphere1);
				//return boxSphere1;
 			}

			float3 getNormal(float3 p)
			{
				const float2 offset = float2(0.001, 0);
				float3 n = float3(
					distanceField(p + offset.xyy) - distanceField(p - offset.xyy),
					distanceField(p + offset.yxy) - distanceField(p - offset.yxy),
					distanceField(p + offset.yyx) - distanceField(p - offset.yyx));

				return normalize(n);
			}

			float HardShadow(float3 ro, float3 rd, float mint, float maxt) {
				float t = mint;
				while (t < maxt){
					float h = distanceField(ro + rd * t);
					if (h < 0.001) {
						return 0.0;
					}		
					t += h;
				}
				return 1.0;
			}

			float SoftShadow(float3 ro, float3 rd, float mint, float maxt, float k) {
				float result = 1.0;
				float t = mint;
				while (t < maxt) {
					float h = distanceField(ro + rd * t);
					if (h < 0.001) {
						return 0.0;
					}
					result = min(result, k*h / t);
					t += h;
				}
				return result;
			}

			uniform float _AoStepSize, _AoIntensity;;
			uniform int _AoIterations;

			float AmbientOcclusion(float3 p, float3 n) 
			{
				float step = _AoStepSize;
				float ao = 0.0;
				float dist;
				for (int i = 1; i <= _AoIterations; i++) {
					dist = step * i;
					ao += max(0.0, (dist - distanceField(p + n * dist))/dist);
				}
				return (1.0 - ao * _AoIntensity);

			}

			float3 Shading(float3 p, float3 n) {
				float3 result;
				// Diffuse Color
				float3 color = _mainColor.rgb;

				// Directional light
				float3 light = (_LightCol * dot(-_lightDir, n) * 0.5 + 0.5) * _LightIntensity;

				// Shadows
				float shadow = SoftShadow(p, -_lightDir, _ShadowDistance.x, _ShadowDistance.y, _ShadowPenumbra) * 0.5 + 0.5;
				shadow = max(0,pow(shadow, _ShadowIntensity));

				//Ambient Occlusion
				float ao = AmbientOcclusion(p, n);

				result = color * light * shadow * ao;

				return result;
			}

			fixed4 raymarching(float3 ro, float3 rd, float depth) 
			{
				fixed4 result = fixed4(1, 1, 1, 1);
				const int max_iterarion = _MaxIterations;
				float t = 0; //distanced traveled along ray

				for (int i = 0; i < max_iterarion; i++) {
					if (t > _maxDistance || t >= depth) 
					{
						//Environment
						result = fixed4(rd, 0);
						break;
					}

					float3 p = ro + rd * t;
					// check for hit in distance field
					float d = distanceField(p);
					if (d < _Accuracy) // We have hit something
					{
						// shading!
						float3 n = getNormal(p);
						float3 s = Shading(p, n);

						result = fixed4(fixed3(s),1);
						break;
					}
					t += d;
				}

				return result;
			}

			fixed4 frag(v2f i) : SV_Target
			{
				float depth = LinearEyeDepth(tex2D(_CameraDepthTexture, i.uv).r);
				depth *= length(i.ray);
				fixed3 col = tex2D(_MainTex, i.uv);
				float3 rayDirection = normalize(i.ray.xyz);
				float3 rayOrigin = _WorldSpaceCameraPos;
				fixed4 result = raymarching(rayOrigin, rayDirection, depth);
				return fixed4(col * (1.0 - result.w) + result.xyz * result.w ,1.0);
            }
            ENDCG
        }
    }
}
