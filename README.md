# MDMF PDF 추출기

Windows 뷰어 없이 MDMF에 들어 있는 PDF 본문을 Mac에서 추출합니다. 별도 프로그램이나 Python을 설치할 필요가 없습니다.

## 사용 방법

1. 저장소의 **MDMF-PDF-Extractor.zip**을 내려받아 압축을 풀고 **MDMF PDF 추출기.app**을 더블클릭합니다.
2. **파일 선택…**으로 `.mdmf` 파일을 선택하거나, 앱 창으로 끌어놓습니다. 여러 파일도 한 번에 처리할 수 있습니다.
3. 완료 후 **PDF 열기**를 누릅니다. **Finder에서 보기**로 저장된 파일을 찾을 수도 있습니다.

기본 저장 위치는 원본 MDMF와 같은 폴더입니다. **변경…**으로 다른 폴더를 선택할 수 있습니다. 예를 들어 `공문.mdmf`는 `공문.pdf`로 저장되고, 같은 이름이 이미 있으면 `공문 (2).pdf`처럼 번호를 붙입니다.

Finder의 **연결 프로그램**에서 이 앱을 선택하거나 앱 아이콘 위에 MDMF를 놓아도 됩니다. 앱은 어디로 옮겨도 실행되며, 자주 쓰면 응용 프로그램 폴더에 넣어 두면 됩니다.

## 지원 범위

- macOS 13 이상용 Universal 앱: Apple Silicon 및 Intel 바이너리를 포함합니다. 실제 실행 검증은 현재 Apple Silicon Mac에서 했습니다.
- 검증된 MarkAny 뷰어와 샘플에서 확인한 **MDMFILEFXC / 버전 11 / 2,227바이트 헤더** 형식을 지원합니다.
- 최대 파일 크기: 100 MB.
- 추출한 PDF의 형식과 페이지를 검사한 후 저장합니다. 다른 MDMF 변형, 사용자 암호가 필요한 문서, PDF가 아닌 본문, 손상된 파일은 지원하지 않습니다.
- 원본의 PDF 바이트를 추출합니다. 본문을 다시 조판하거나 이미지로 바꾸지 않습니다.
- MDMF 원본은 그대로 유지됩니다. MDMF에 별도로 포함된 부가 정보와 전용 뷰어의 진위 확인·전자서명 검증 기능은 PDF 추출 결과에 포함되지 않습니다.
- 파일을 서버로 보내거나 Windows 설치 파일을 실행하지 않습니다.

이 앱은 제공된 파일 형식에 맞춰 만든 독립 도구이며 MarkAny의 공식 앱이 아닙니다. Apple 공증 배포용 앱은 아니므로 다른 Mac으로 전송해 사용할 때는 해당 Mac의 앱 실행 정책을 따릅니다.

## 명령줄 사용

앱 내부 실행 파일도 명령줄 도구로 사용할 수 있습니다.

```sh
"MDMF PDF 추출기.app/Contents/MacOS/mdmf-extract" --extract "공문.mdmf"
"MDMF PDF 추출기.app/Contents/MacOS/mdmf-extract" --extract "공문1.mdmf" "공문2.mdmf" --output-dir "저장폴더"
"MDMF PDF 추출기.app/Contents/MacOS/mdmf-extract" --help
```

상대 경로는 현재 터미널 폴더 기준입니다. 출력 폴더는 미리 존재해야 합니다. 성공 시 종료 코드는 0, 추출 실패가 있으면 1, 옵션 오류는 2입니다.

## 소스와 다시 빌드하기

이 저장소에는 Swift 소스와 빌드 스크립트가 포함되어 있습니다. Xcode Command Line Tools가 설치된 Mac에서 다음 명령으로 재빌드합니다.

```sh
bash build.sh
```

결과는 `build/MDMF PDF 추출기.app`입니다. 시스템의 Foundation, CommonCrypto, PDFKit, AppKit을 사용하며 외부 패키지 의존성이 없습니다.

## 테스트

로컬에 보관한 검증용 MDMF 파일과 독립적으로 확인한 PDF를 사용합니다. 회귀 테스트의 정상 입력은 1페이지 PDF를 포함하는 지원 형식입니다. 실제 공문과 추출 결과는 저장소에 포함하지 않습니다.

```sh
xcrun swiftc Extractor.swift CoreTests.swift -o CoreTests
./CoreTests "/path/to/fixture.mdmf" "/path/to/expected.pdf"
```

실제 샘플과의 바이트 일치, 잘린 파일과 잘못된 길이 거부, 원본 보존, 이름 충돌, 한글 파일명, 파일 크기 제한 등 42개 검증을 수행합니다.
