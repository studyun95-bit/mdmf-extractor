# MDMF 파일 추출기

Windows 뷰어 없이 MDMF에 들어 있는 PDF 본문과 ZIP·엑셀·HWP·이미지 등 모든 붙임파일을 Mac에서 추출합니다. 별도 프로그램이나 Python을 설치할 필요가 없습니다.

**1.1 업데이트:** PDF만 추출하던 1.0에서 붙임파일 추출을 추가했습니다. MDMF는 일반 ZIP이 아니라 암호화된 문서 묶음입니다. 내부 PDF를 복호화하고, 붙임파일은 복호화 후 압축을 풀어 원래 파일로 저장합니다. [확인한 파일 구조](FORMAT.md)도 정리했습니다.

## 사용 방법

DMG 설치 파일이 있으면 열고 **MDMF 파일 추출기.app**을 **Applications** 폴더로 끌어 넣으세요. 설치 후 응용 프로그램 폴더에서 실행합니다. ZIP 배포본은 아래 방법으로 실행할 수 있습니다.

1. 저장소의 **MDMF-PDF-Extractor.zip**을 내려받아 압축을 풀고 **MDMF 파일 추출기.app**을 더블클릭합니다.
2. **파일 선택…**으로 `.mdmf` 파일을 선택하거나, 앱 창으로 끌어놓습니다. 여러 파일도 한 번에 처리할 수 있습니다.
3. 완료 후 **PDF 열기**로 공문을 읽거나, **Finder에서 보기**로 PDF와 붙임파일을 확인합니다. 붙임파일은 원래 이름과 확장자로 저장됩니다.

붙임파일은 확장자에 관계없이 원래 이름과 바이트 그대로 추출합니다. ZIP은 ZIP으로, 엑셀은 XLS·XLSX로 저장하며, 이미지·텍스트·알 수 없는 확장자도 동일하게 처리합니다. 붙임 ZIP 안의 파일을 추가로 풀거나 문서를 PDF로 변환하지 않습니다. 추출한 파일은 각 형식에 맞는 앱으로 열면 됩니다.

기본 저장 위치는 원본 MDMF와 같은 폴더입니다. **변경…**으로 다른 폴더를 선택할 수 있습니다. 예를 들어 `공문.mdmf`는 `공문.pdf`로 저장되고, 같은 이름이 이미 있으면 `공문 (2).pdf`처럼 번호를 붙입니다.

Finder의 **연결 프로그램**에서 이 앱을 선택하거나 앱 아이콘 위에 MDMF를 놓아도 됩니다. 앱은 어디로 옮겨도 실행되며, 자주 쓰면 응용 프로그램 폴더에 넣어 두면 됩니다.

## 지원 범위

- macOS 13 이상용 Universal 앱: Apple Silicon 및 Intel 바이너리를 포함합니다. 실제 실행 검증은 현재 Apple Silicon Mac에서 했습니다.
- 검증된 MarkAny 뷰어와 샘플에서 확인한 **MDMFILEFXC / 버전 11 / 2,227바이트 헤더** 형식을 지원합니다.
- 입력 파일과 압축을 푼 전체 출력 크기는 각각 최대 100 MB입니다.
- 추출한 PDF의 형식과 페이지를 검사한 후 저장합니다. 다른 MDMF 변형, 사용자 암호가 필요한 문서, PDF가 아닌 본문, 손상된 파일은 지원하지 않습니다.
- 원본의 PDF 바이트와 MATTACHDAT 영역의 붙임파일 바이트를 추출합니다. 본문을 다시 조판하거나 이미지로 바꾸지 않습니다.
- MDMF 원본은 그대로 유지됩니다. 전용 뷰어의 진위 확인·전자서명 검증 기능은 포함하지 않습니다.
- 파일을 서버로 보내거나 Windows 설치 파일을 실행하지 않습니다.

이 앱은 제공된 파일 형식에 맞춰 만든 독립 도구이며 MarkAny의 공식 앱이 아닙니다. Apple 공증 배포용 앱은 아니므로 다른 Mac으로 전송해 사용할 때는 해당 Mac의 앱 실행 정책을 따릅니다.

## 명령줄 사용

앱 내부 실행 파일도 명령줄 도구로 사용할 수 있습니다.

```sh
"MDMF 파일 추출기.app/Contents/MacOS/mdmf-extract" --extract "공문.mdmf"
"MDMF 파일 추출기.app/Contents/MacOS/mdmf-extract" --extract "공문1.mdmf" "공문2.mdmf" --output-dir "저장폴더"
"MDMF 파일 추출기.app/Contents/MacOS/mdmf-extract" --help
```

상대 경로는 현재 터미널 폴더 기준입니다. 출력 폴더는 미리 존재해야 합니다. 성공 시 종료 코드는 0, 추출 실패가 있으면 1, 옵션 오류는 2입니다.

## 소스와 다시 빌드하기

이 저장소에는 Swift 소스와 빌드 스크립트가 포함되어 있습니다. Xcode Command Line Tools가 설치된 Mac에서 다음 명령으로 재빌드합니다.

```sh
bash build.sh
```

결과는 `build/MDMF 파일 추출기.app`입니다. 시스템의 Foundation, CommonCrypto, PDFKit, AppKit, zlib을 사용하며 외부 패키지 의존성이 없습니다.

DMG 설치 파일은 앱 빌드 후 다음 명령으로 만듭니다. 앱과 Applications 바로가기, 설치 안내만 포함됩니다.

```sh
bash make-dmg.sh
```

결과는 `build/MDMF-Extractor-1.1.dmg`입니다. 기존 앱과 출력 위치를 직접 지정할 수도 있습니다.

```sh
bash make-dmg.sh "앱 경로/MDMF 파일 추출기.app" "출력 경로/MDMF-Extractor-1.1.dmg"
```

## 테스트

로컬에 보관한 검증용 MDMF 파일과 독립적으로 확인한 PDF를 사용합니다. 회귀 테스트의 정상 입력은 1페이지 PDF를 포함하는 지원 형식입니다. 실제 공문과 추출 결과는 저장소에 포함하지 않습니다.

```sh
xcrun swiftc Extractor.swift CoreTests.swift -o CoreTests
./CoreTests "/path/to/fixture.mdmf" "/path/to/expected.pdf"
```

실제 샘플과의 바이트 일치, 붙임파일 복호화 및 압축 해제, 잘린 파일과 잘못된 길이 거부, 원본 보존, 이름 충돌, 한글 파일명, 경로 검증, 압축 해제 크기 제한을 검증합니다. 붙임파일 테스트 데이터는 테스트에서 생성합니다.
