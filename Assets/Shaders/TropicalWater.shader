Shader "Custom/TropicalWater"
{
    Properties
    {
        [Header(Water Colors)]
        _DeepWaterColor ("Deep Water Color", Color) = (0.05, 0.35, 0.65, 0.85)
        _ShallowWaterColor ("Shallow Water Color", Color) = (0.25, 0.85, 0.80, 0.45)
        _Depth ("Depth", Float) = 1.0
        _Strength ("Strength", Range(0, 2)) = 1.0

        [Header(Normal Maps)]
        [Normal] _NormalMapA ("Normal Map A", 2D) = "bump" {}
        [Normal] _NormalMapB ("Normal Map B", 2D) = "bump" {}
        _NormalStrength ("Normal Strength", Float) = 0.8
        _Smoothness ("Smoothness", Range(0, 1)) = 0.85

        [Header(Vertex Displacement)]
        _Displacement ("Displacement", Float) = 0.15
    }

    SubShader
    {
        Tags 
        { 
            "RenderType" = "Transparent" 
            "Queue" = "Transparent" 
            "RenderPipeline" = "UniversalPipeline" 
            "IgnoreProjector" = "True"
        }
        
        LOD 300
        Blend SrcAlpha OneMinusSrcAlpha
        ZWrite Off
        Cull Back

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex vert
            #pragma fragment frag

            // URP keywords
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float3 normalOS     : NORMAL;
                float4 tangentOS    : TANGENT;
                float2 uv           : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS   : SV_POSITION;
                float2 uv           : TEXCOORD0;
                float4 screenPos    : TEXCOORD1;
                float3 positionWS   : TEXCOORD2;
                float3 normalWS     : TEXCOORD3;
                float3 tangentWS    : TEXCOORD4;
                float3 bitangentWS  : TEXCOORD5;
            };

            CBUFFER_START(UnityPerMaterial)
                float4 _DeepWaterColor;
                float4 _ShallowWaterColor;
                float _Depth;
                float _Strength;
                float _NormalStrength;
                float _Smoothness;
                float _Displacement;
            CBUFFER_END

            TEXTURE2D(_NormalMapA);
            SAMPLER(sampler_NormalMapA);
            TEXTURE2D(_NormalMapB);
            SAMPLER(sampler_NormalMapB);

            // 2D Hash & Gradient noise implementation
            float2 Hash22(float2 p)
            {
                p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
                return -1.0 + 2.0 * frac(sin(p) * 43758.5453123);
            }

            float GradientNoise(float2 uv)
            {
                float2 p = floor(uv);
                float2 f = frac(uv);
                float2 w = f * f * (3.0 - 2.0 * f);

                return lerp(
                    lerp(dot(Hash22(p + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
                         dot(Hash22(p + float2(1.0, 0.0)), f - float2(1.0, 0.0)), w.x),
                    lerp(dot(Hash22(p + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
                         dot(Hash22(p + float2(1.0, 1.0)), f - float2(1.0, 1.0)), w.x),
                    w.y);
            }

            Varyings vert(Attributes input)
            {
                Varyings output;

                // Vertex Displacement (Waves):
                // Split Object Space Position, animate Gradient Noise (scale ~20) driven by Time / 100
                float3 posOS = input.positionOS.xyz;
                float timeWave = _Time.y / 100.0;
                float2 noiseUV = (posOS.xz + timeWave) * 20.0;
                float waveNoise = GradientNoise(noiseUV);
                posOS.y += waveNoise * _Displacement;

                VertexPositionInputs vertexInput = GetVertexPositionInputs(posOS);
                VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);

                output.positionCS = vertexInput.positionCS;
                output.positionWS = vertexInput.positionWS;
                output.screenPos  = ComputeScreenPos(vertexInput.positionCS);
                output.uv         = input.uv;

                output.normalWS    = normalInput.normalWS;
                output.tangentWS   = normalInput.tangentWS;
                output.bitangentWS = normalInput.bitangentWS;

                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                // Depth-Based Gradient (Shallow vs. Deep Water):
                float2 screenUV = input.screenPos.xy / max(input.screenPos.w, 0.00001);
                
                #if UNITY_REVERSED_Z
                    float rawDepth = SampleSceneDepth(screenUV);
                #else
                    float rawDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, SampleSceneDepth(screenUV));
                #endif

                float sceneDepth = LinearEyeDepth(rawDepth, _ZBufferParams);
                float waterDepth = input.screenPos.w; // clip space A / Eye Depth

                // Subtract screen space position from multiplied depth value to create depth gradient
                // Combine with split clip space A added to Depth property
                float depthDiff = (sceneDepth - waterDepth) / max(_Depth, 0.001);
                float gradientMask = saturate(depthDiff * _Strength);

                // Lerp between Shallow and Deep colors
                half4 waterColor = lerp(_ShallowWaterColor, _DeepWaterColor, gradientMask);

                // Normal Maps & Surface Texturing:
                // Tiling and offset 100, animated opposite via Time / 50 and Time / -25
                float timeA = _Time.y / 50.0;
                float timeB = _Time.y / -25.0;
                float2 uvA = input.uv * 100.0 + float2(timeA, timeA * 0.7);
                float2 uvB = input.uv * 100.0 + float2(timeB * 0.8, timeB);

                half4 normalSampleA = SAMPLE_TEXTURE2D(_NormalMapA, sampler_NormalMapA, uvA);
                half4 normalSampleB = SAMPLE_TEXTURE2D(_NormalMapB, sampler_NormalMapB, uvB);

                half3 nA = UnpackNormal(normalSampleA);
                half3 nB = UnpackNormal(normalSampleB);

                // Combine normal maps (Whiteout blend)
                half3 combinedNormal = normalize(half3(nA.xy + nB.xy, nA.z * nB.z));

                // Normal strength masked by depth gradient so normal details fade near shoreline
                float effNormalStrength = _NormalStrength * gradientMask;
                combinedNormal = normalize(lerp(half3(0, 0, 1), combinedNormal, effNormalStrength));

                // Transform normal to world space
                half3x3 tangentToWorld = half3x3(input.tangentWS, input.bitangentWS, input.normalWS);
                half3 worldNormal = normalize(mul(combinedNormal, tangentToWorld));

                // Lighting calculation (PBR/Lit)
                InputData inputData;
                inputData.positionWS = input.positionWS;
                inputData.normalWS = worldNormal;
                inputData.viewDirectionWS = GetWorldSpaceNormalizeViewDir(input.positionWS);
                inputData.shadowCoord = TransformWorldToShadowCoord(input.positionWS);
                inputData.fogCoord = 0;
                inputData.vertexLighting = half3(0, 0, 0);
                inputData.bakedGI = SampleSH(worldNormal);
                inputData.normalizedScreenSpaceUV = screenUV;
                inputData.shadowMask = half4(1, 1, 1, 1);

                #if defined(UNIVERSAL_LIGHTING_INCLUDED)
                Light mainLight = GetMainLight(inputData.shadowCoord);
                half3 lightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);
                half NdotL = saturate(dot(worldNormal, mainLight.direction));
                half3 diffuse = waterColor.rgb * (inputData.bakedGI + lightColor * NdotL);

                // Specular highlights / reflections driven by Smoothness
                half3 halfDir = normalize(mainLight.direction + inputData.viewDirectionWS);
                half NdotH = saturate(dot(worldNormal, halfDir));
                half specPower = exp2(10.0 * _Smoothness + 1.0);
                half specular = pow(NdotH, specPower) * _Smoothness;
                half3 finalColor = diffuse + specular * lightColor;
                #else
                half3 finalColor = waterColor.rgb;
                #endif

                return half4(finalColor, waterColor.a);
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
