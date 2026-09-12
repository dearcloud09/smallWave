# smallWave 실행 안내

개발 중인 iPhone 시제품이다. 액체 재질과 빠른 반복 흔들림은 아직 개선 대상이다. 현재 앱의 파란 액체 물리와 투명한 주변 매질의 광학 표현을 실제 물·기름 두 유체 시뮬레이션으로 해석하지 않는다.

## 준비

Xcode의 첫 실행 설정과 iOS 플랫폼, Metal Toolchain을 준비한다. 프로젝트의 최소 배포 대상은 iOS 17이며, 실제 기기 실행에는 그 기기의 iOS를 지원하는 Xcode가 필요하다.

`SmallWave.xcodeproj`를 열고 `SmallWave` scheme을 선택한다. 앱과 위젯은 함께 빌드된다. 물리 계산을 위해 앱의 Debug 설정도 Swift 최적화를 사용한다.

## 서명 없이 컴파일

저장소 루트에서 실행한다.

```sh
sh scripts/build-ios.sh simulator
sh scripts/build-ios.sh device
```

기본 산출물 위치는 `/private/tmp/smallwave-xcode/DerivedData-simulator/`와 `DerivedData-device/`다. `SMALLWAVE_DERIVED_DATA_ROOT`로 다른 임시 경로를 지정할 수 있다.

## 실제 아이폰에서 실행

1. Xcode의 Apple Accounts에서 개발에 사용할 계정으로 로그인한다.
2. `Config/Signing.example.xcconfig`를 `Config/Signing.local.xcconfig`로 복사하고 `YOUR_TEAM_ID`를 해당 Apple 개발 팀 ID로 바꾼다. 이 파일은 Git에서 제외되며 앱·위젯에 같은 팀을 적용한다.
3. 아이폰을 연결하고 잠금을 푼다. 기기의 신뢰 확인과 [개발자 모드](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)를 완료한다.
4. Xcode에서 연결한 실제 아이폰을 실행 대상으로 선택하고 실행한다. 테스트용 bundle ID는 `dev.smallwave.prototype` 및 `.widget`이다. 자신의 팀에서 사용할 ID가 필요하면 앱과 위젯을 함께 조정한다.

명령줄에서 서명된 앱을 만들려면:

```sh
sh scripts/build-ios.sh device --signed
```

산출물은 `DerivedData-device-signed/Build/Products/Debug-iphoneos/SmallWave.app`에 있다. 이 명령 자체는 기기에 설치하지 않는다. 암호·인증서·프로비저닝 프로파일은 저장소에 넣지 않는다.

## 검사와 미리보기

```sh
sh scripts/test-core.sh
sh scripts/test-render.sh
sh scripts/render-live.sh
```

첫 검사는 물리와 센서 시간순 입력의 경계를 확인한다. 렌더 검사는 Metal GPU를 사용할 수 있는 Mac이 필요하다. 출력은 `.build-cache/`에 저장되며 Git에서 제외된다. 합성 입력으로 만든 Mac 미리보기와 실제 iPhone 화면·손맛·성능은 별도의 증거다.

`Studies/`의 후보와 기록에는 미채택·실패한 방법도 있다. 앱의 실제 구현은 `SmallWave/`와 Xcode의 Sources 목록을 기준으로 확인한다.

## 20초 기기 성능 집계

기본 아이콘 실행에서는 계측하지 않는다. 개발 도구로 `--smallwave-frame-timing=<고유ID>` 실행 인자를 전달하면 CPU·GPU·물리 시간 비율을 20초 집계한다. ID는 영문·숫자·밑줄·하이픈으로 1~64자다.

앱 캐시의 `smallwave-frame-timing.json` 한 개에 집계가 저장된다. 읽을 때 반드시 예상한 `captureID`, `appBuild`, 생성 UTC 시각을 대조한다. `acceptedHz`는 렌더러가 수락한 프레임 빈도이며 화면 표시 FPS나 센서 지연을 직접 측정한 값이 아니다. 250ms를 넘는 구간은 시간 비율에서 제외되므로 제외 횟수도 함께 본다.

## 실제 사용 확인

- 정지·느린 기울임·빠른 흔들기 후의 수면 안정과 수위 복구.
- 뒤집었을 때 범선의 잠김과 다시 세웠을 때 재부상.
- 앞뒤 기울임·화면 회전·앱 중단과 재개.
- 무음 모드·소리 미리듣기·진동·정지 위젯에서 앱으로 이동.

현재 물소리는 음악이 아닌 합성 소리다. 바다 설정에서 켜고 2초 미리듣기로 확인할 수 있다. 실물 같은 음색은 후속 개선 대상이다.
