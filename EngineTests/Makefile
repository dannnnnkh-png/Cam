# 影音核心測試（macOS：brew install ffmpeg pkg-config；Linux：apt install libavformat-dev libavcodec-dev libswresample-dev pkg-config）
# 需要 /tmp/testmedia/ 測試影片，執行 make media 產生
LIBS = $(shell pkg-config --cflags --libs libavformat libavcodec libavutil libswresample)

test: test_engine
	./test_engine

test_engine: test_engine.c ../HomeCam/Engine/HCEngine.c ../HomeCam/Engine/HCEngine.h
	cc -O1 -g -Wall -Wno-unused-result -U__APPLE__ -fsanitize=address,undefined -o $@ test_engine.c ../HomeCam/Engine/HCEngine.c $(LIBS) -lpthread

media:
	mkdir -p /tmp/testmedia
	ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=1280x720:rate=15" -f lavfi -i "sine=frequency=440:sample_rate=16000" \
	  -af "volume='if(lt(mod(t,4),2),1,0.01)':eval=frame" -t 60 -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 30 -c:a aac /tmp/testmedia/cam.mp4
	ffmpeg -y -loglevel error -f lavfi -i "color=c=gray:size=640x360:rate=10" -t 30 -c:v libx264 -preset veryfast -pix_fmt yuv420p /tmp/testmedia/static.mp4
	ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=640x360:rate=10" -f lavfi -i "sine=sample_rate=8000" -t 20 \
	  -c:v libx265 -preset ultrafast -x265-params keyint=20:log-level=error -c:a pcm_alaw -f matroska /tmp/testmedia/hevc_gop.mkv
	cp /tmp/testmedia/hevc_gop.mkv /tmp/testmedia/hevc.mkv

clean:
	rm -f test_engine
