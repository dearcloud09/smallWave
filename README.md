# smallWave

손 안의 작은 Liquid Wave 장난감을 만드는 iPhone 앱 시제품.

휴대폰을 기울이거나 흔들면 파란 액체와 작은 범선이 움직인다. 실제 장난감처럼 액체가 뭉치고 갈라졌다가 합쳐지는 느낌을 목표로 개발하고 있다.

## 현재 구현

- SwiftUI 앱, Core Motion 입력, 120Hz의 얕은 3차원 입자 물리.
- Metal 볼륨 필드와 굴절·투과 렌더링, 기포와 범선의 잠김·재부상.
- 작은 장난감 범선의 세 가지 색상, 일시정지·초기화·소리·진동 설정.
- WidgetKit 기본 정지 위젯과 앱으로 이동하는 링크.
- 개발자가 명시적으로 실행한 경우에만 기록하는 20초 로컬 성능 집계.

실물의 물·기름 질감과 빠른 반복 흔들림은 개선 중이다. 투명한 두 번째 액체는 별도 동역학으로 계산하지 않는다. 연구 후보를 앱에 채택한 것으로 보지 않으며, 스토어 배포용 완성 버전도 아니다.

## 실행

Xcode와 iOS SDK, Metal Toolchain이 필요하다. 프로젝트의 최소 배포 대상은 iOS 17이다. 실제 기기에 설치하려면 해당 기기의 iOS를 지원하는 Xcode와 개발 서명이 필요하다.

```sh
sh scripts/build-ios.sh simulator
sh scripts/test-core.sh
```

기기 서명은 `Config/Signing.example.xcconfig`를 `Config/Signing.local.xcconfig`로 복사하고 팀 ID를 입력한다. 로컬 서명 파일은 Git에서 제외된다.

```sh
sh scripts/build-ios.sh device --signed
```

자세한 방법은 [실행 안내](GETTING_STARTED.md)에 있다. 개인 계정·프로파일·기기 녹화·빌드 캐시는 저장소에 포함하지 않는다.

## 구조

- `SmallWave/`: 앱·물리·렌더러·리소스.
- `SmallWaveWidget/`: 위젯 확장.
- `Tests/`, `scripts/`: 물리·입력·렌더 검사와 개발 도구.
- `Studies/`: 실험 구현과 채택 여부를 구분한 연구 기록.
- `References/miniature-art-direction/toy-v2/`: 제작한 범선의 합성 비교와 검증 자료.

그래픽 미리보기는 별도 표시가 없으면 Mac에서 합성 입력으로 만든 결과다. 실제 iPhone 센서 반응이나 성능 측정과 구분한다.
