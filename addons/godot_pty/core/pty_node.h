#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <mutex>
#include <thread>

namespace godot {

class PTYNode : public Node {
    GDCLASS(PTYNode, Node)

private:
    int master_fd = -1;
    pid_t child_pid = -1;
    std::atomic<bool> running{false};
    std::thread read_thread;
    std::mutex write_mutex;

    void _read_loop();

protected:
    static void _bind_methods();

public:
    PTYNode();
    ~PTYNode();

    // Opens a PTY and forks a shell. Returns the child PID on success, -1 on error.
    int open(int cols, int rows, const String &shell);

    // Writes raw bytes to the PTY master fd.
    void write(const PackedByteArray &data);

    // Sends SIGWINCH and updates the kernel winsize struct.
    void resize(int cols, int rows);

    // Kills the child and closes the master fd.
    void close_pty();

    bool is_open() const;

    void _exit_tree() override;
};

} // namespace godot
