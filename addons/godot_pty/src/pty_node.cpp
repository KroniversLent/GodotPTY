#include "pty_node.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

// PTY / terminal headers
#ifdef __linux__
#  include <pty.h>
#elif defined(__APPLE__)
#  include <util.h>
#endif

#include <cerrno>
#include <chrono>
#include <cstring>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <signal.h>

namespace godot {

PTYNode::PTYNode() {}

PTYNode::~PTYNode() {
    close_pty();
}

void PTYNode::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("open", "cols", "rows", "shell"),
        &PTYNode::open,
        DEFVAL(80), DEFVAL(24), DEFVAL("/bin/bash"));

    ClassDB::bind_method(D_METHOD("write", "data"), &PTYNode::write);
    ClassDB::bind_method(D_METHOD("resize", "cols", "rows"), &PTYNode::resize);
    ClassDB::bind_method(D_METHOD("close_pty"), &PTYNode::close_pty);
    ClassDB::bind_method(D_METHOD("is_open"), &PTYNode::is_open);

    ADD_SIGNAL(MethodInfo("data_received",
        PropertyInfo(Variant::PACKED_BYTE_ARRAY, "data")));
    ADD_SIGNAL(MethodInfo("exited",
        PropertyInfo(Variant::INT, "exit_code")));
}

void PTYNode::_exit_tree() {
    close_pty();
}

int PTYNode::open(int cols, int rows, const String &shell) {
    if (master_fd >= 0) {
        close_pty();
    }

    struct winsize ws{};
    ws.ws_col = static_cast<unsigned short>(cols);
    ws.ws_row = static_cast<unsigned short>(rows);

    // forkpty: creates master/slave pair, forks, connects slave to child stdio
    child_pid = forkpty(&master_fd, nullptr, nullptr, &ws);

    if (child_pid < 0) {
        UtilityFunctions::printerr("PTYNode: forkpty failed: ", std::strerror(errno));
        return -1;
    }

    if (child_pid == 0) {
        // Child process — exec the shell
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        const char *sh = shell.utf8().get_data();
        execl(sh, sh, nullptr);
        // Only reached if exec fails
        _exit(127);
    }

    // Parent process
    running.store(true);
    read_thread = std::thread(&PTYNode::_read_loop, this);
    return static_cast<int>(child_pid);
}

void PTYNode::_read_loop() {
    uint8_t buf[4096];

    while (running.load()) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(master_fd, &fds);

        // 50 ms timeout so we notice when `running` turns false
        struct timeval tv{0, 50000};
        int ret = select(master_fd + 1, &fds, nullptr, nullptr, &tv);

        if (ret < 0) {
            if (errno == EINTR) continue;
            break; // master_fd was closed
        }
        if (ret == 0) continue; // timeout

        ssize_t n = ::read(master_fd, buf, sizeof(buf));
        if (n > 0) {
            PackedByteArray data;
            data.resize(static_cast<int>(n));
            std::memcpy(data.ptrw(), buf, static_cast<size_t>(n));
            // Defer to the main thread — call_deferred is thread-safe
            call_deferred("emit_signal", "data_received", data);
        } else if (n == 0) {
            break; // EOF
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
    }

    running.store(false);

    // Reap the child and report its exit code
    if (child_pid > 0) {
        int status = 0;
        waitpid(child_pid, &status, 0);
        int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        call_deferred("emit_signal", "exited", exit_code);
    }
}

void PTYNode::write(const PackedByteArray &data) {
    if (master_fd < 0 || data.size() == 0) return;

    std::lock_guard<std::mutex> lock(write_mutex);
    const uint8_t *ptr = data.ptr();
    ssize_t total = 0;
    ssize_t len = static_cast<ssize_t>(data.size());
    while (total < len) {
        ssize_t n = ::write(master_fd, ptr + total, static_cast<size_t>(len - total));
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        total += n;
    }
}

void PTYNode::resize(int cols, int rows) {
    if (master_fd < 0) return;
    struct winsize ws{};
    ws.ws_col = static_cast<unsigned short>(cols);
    ws.ws_row = static_cast<unsigned short>(rows);
    ioctl(master_fd, TIOCSWINSZ, &ws);
    if (child_pid > 0) {
        kill(child_pid, SIGWINCH);
    }
}

void PTYNode::close_pty() {
    running.store(false);

    if (master_fd >= 0) {
        ::close(master_fd); // wakes up select() in the read thread
        master_fd = -1;
    }
    if (child_pid > 0) {
        kill(child_pid, SIGTERM);
        waitpid(child_pid, nullptr, WNOHANG);
        child_pid = -1;
    }
    if (read_thread.joinable()) {
        read_thread.join();
    }
}

bool PTYNode::is_open() const {
    return master_fd >= 0;
}

} // namespace godot
