/* webcam-flip-keeper — SPDX-License-Identifier: GPL-3.0-only
 * Copyright (C) 2026 onexplayer-webcam-flip contributors
 *
 * Minimal v4l2loopback writer that keeps the device openable while idle.
 * v4l2loopback fails capture VIDIOC_STREAMON with EIO when no writer is
 * streaming, so something must always write. This writes black YUYV
 * frames via write(); write() blocks when the buffer queue is full, so
 * the process costs ~0 CPU while nobody is reading.
 *
 * Usage: webcam-flip-keeper [device] [width] [height] [fps]
 * Pixel format is fixed to YUYV (the Super X camera's native format).
 *
 * Exits on SIGTERM/SIGINT (write() returns EINTR).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

static volatile sig_atomic_t stop = 0;
static void on_sig(int sig) { (void)sig; stop = 1; }

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/video10";
    int width = argc > 2 ? atoi(argv[2]) : 1280;
    int height = argc > 3 ? atoi(argv[3]) : 720;
    int fps = argc > 4 ? atoi(argv[4]) : 10;

    if (width <= 0 || height <= 0 || fps <= 0) {
        fprintf(stderr, "keeper: invalid arguments\n");
        return 1;
    }

    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.bytesperline = width * 2;
    fmt.fmt.pix.sizeimage = width * height * 2;
    if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) { perror("S_FMT"); return 1; }

    size_t size = fmt.fmt.pix.sizeimage;
    unsigned char *buf = calloc(1, size);
    if (!buf) { perror("calloc"); return 1; }

    /* Black in YUYV is Y=0 with neutral chroma (U=V=128); an all-zero
     * buffer renders green (Cb/Cr are centred at 128, so 0 pushes the
     * pixel towards green). YUYV layout is [Y0, U, Y1, V, ...]. */
    for (size_t i = 1; i < size; i += 2)
        buf[i] = 128;

    signal(SIGTERM, on_sig);
    signal(SIGINT, on_sig);
    signal(SIGPIPE, SIG_IGN);
    fprintf(stderr, "keeper: streaming %dx%d YUYV black frames at %d fps\n",
            width, height, fps);

    while (!stop) {
        ssize_t n = write(fd, buf, size);
        if (n < 0) {
            if (errno == EINTR) break;
            if (errno != EAGAIN) { perror("write"); return 1; }
        }
        usleep(1000000 / fps);
    }
    fprintf(stderr, "keeper: exiting\n");
    return 0;
}
