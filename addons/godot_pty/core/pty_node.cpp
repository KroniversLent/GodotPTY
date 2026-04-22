#include "pty_node.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifdef __linux__
#  include <pty.h>
#elif defined(__APPLE__)
#  include <util.h>
#endif

#include <sys/select.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <signal.h>
#include <cstring>
#include <errno.h>

namespace godot {

PTYNode::PTYNode() : master_fd(-1), child_pid(-1) {}
PTYNode::~PTYNode() { close_pty(); }

void PTYNode::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open", "cols", "rows", "shell"), &PTYNode::open, DEFVAL(80), DEFVAL(24), DEFVAL("/bin/bash"));
    ClassDB::bind_method(D_METHOD("write", "data"), &PTYNode::write);
    ClassDB::bind_method(D_METHOD("resize", "cols", "rows"), &PTYNode::resize);
    ClassDB::bind_method(D_METHOD("close_pty"), &PTYNode::close_pty);
    ClassDB::bind_method(D_METHOD("is_open"), &PTYNode::is_open);

    ADD_SIGNAL(MethodInfo("data_received", PropertyInfo(Variant::PACKED_BYTE_ARRAY, "data")));
    ADD_SIGNAL(MethodInfo("exited", PropertyInfo(Variant::INT, "exit_code")));
}

int PTYNode::open(int cols, int rows, const String &shell) {
    if (master_fd >= 0) close_pty();

    struct winsize ws{ (unsigned short)rows, (unsigned short)cols, 0, 0 };
    child_pid = forkpty(&master_fd, nullptr, nullptr, &ws);

    if (child_pid < 0) return -1;

    if (child_pid == 0) {
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("LANG", "en_US.UTF-8", 1);
        const char *sh = shell.utf8().get_data();
        execl(sh, sh, nullptr);
        _exit(127);
    }

    running.store(true);
    read_thread = std::thread(&PTYNode::_read_loop, this);
    return (int)child_pid;
}

void PTYNode::_read_loop() {
    uint8_t buf[16384]; // 16KB buffer for high-throughput
    while (running.load()) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(master_fd, &fds);

        // Blocking select with 100ms timeout for graceful shutdown check
        struct timeval tv{0, 100000};
        int ret = select(master_fd + 1, &fds, nullptr, nullptr, &tv);
        if (ret <= 0) {
            if (ret < 0 && errno == EINTR) continue;
            if (ret == 0) continue; // Timeout, check running again
            break;
        }

        ssize_t n = ::read(master_fd, buf, sizeof(buf));
        if (n > 0) {
            PackedByteArray data;
            data.resize((int)n);
            std::memcpy(data.ptrw(), buf, (size_t)n);
            call_deferred("emit_signal", "data_received", data);
        } else break;
    }
    running.store(false);
    if (child_pid > 0) {
        int status = 0;
        waitpid(child_pid, &status, 0);
        call_deferred("emit_signal", "exited", WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    }
}

void PTYNode::write(const PackedByteArray &data) {
    if (master_fd < 0 || data.size() == 0) return;
    std::lock_guard<std::mutex> lock(write_mutex);
    ::write(master_fd, data.ptr(), data.size());
}

void PTYNode::resize(int cols, int rows) {
    if (master_fd < 0) return;
    struct winsize ws{ (unsigned short)rows, (unsigned short)cols, 0, 0 };
    ioctl(master_fd, TIOCSWINSZ, &ws);
    if (child_pid > 0) kill(child_pid, SIGWINCH);
}

void PTYNode::close_pty() {
    running.store(false);
    if (read_thread.joinable()) read_thread.join();
    if (master_fd >= 0) { ::close(master_fd); master_fd = -1; }
    if (child_pid > 0) { kill(child_pid, SIGTERM); child_pid = -1; }
}

bool PTYNode::is_open() const { return master_fd >= 0; }

void PTYNode::_exit_tree() {
    close_pty();
}

} // namespace godot
