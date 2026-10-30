/* ikvm_socketpair.h -- included (-include) into JDK 25's libnio UnixDispatcher.c by build-ikvm-native.sh.

   UnixDispatcher.init makes the fd that asynchronous closes dup2 over a channel's fd with socketpair(), keeping one
   end and closing the other. emscripten has no socketpair, so init threw IOException "Function not implemented",
   UnixDispatcher's class initialization failed, and with it every socket class: java.net.Socket, HttpURLConnection
   and SocketChannel threw NoClassDefFoundError, an Error apps don't catch, instead of failing to connect. All that fd
   needs is to read end-of-file once its other end is closed, which a pipe's read end does. Sockets themselves still
   fail, with the IOException a device without a network gives. */

#ifndef IKVM_SOCKETPAIR_H
#define IKVM_SOCKETPAIR_H

#include <sys/socket.h>
#include <unistd.h>

static int ikvm_socketpair(int domain, int type, int protocol, int sv[2])
{
    if (socketpair(domain, type, protocol, sv) == 0)
        return 0;
    return pipe(sv);
}

#define socketpair ikvm_socketpair

#endif
