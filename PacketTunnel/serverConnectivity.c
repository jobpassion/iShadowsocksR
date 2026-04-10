//
//  serverConnectivity.c
//

#include "serverConnectivity.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <errno.h>
#include <netinet/in.h>
#include <string.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>

#define MAXDATASIZE 100

int _internal_connectivity(const struct addrinfo *addr, int timeout_ms);

int serverConnectivity(const char *host, int port, int timeout_ms) {
    int result = -1;
    struct addrinfo *addr = NULL;
    char portString[16];

    do {
        if (host==NULL || port==0) {
            break;
        }
        struct addrinfo hints = { 0 };
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_protocol = IPPROTO_TCP;
        snprintf(portString, sizeof(portString), "%d", port);

        if (getaddrinfo(host, portString, &hints, &addr) != 0) {
            break;
        }

        for (const struct addrinfo *current = addr; current != NULL; current = current->ai_next) {
            if (current->ai_family != AF_INET && current->ai_family != AF_INET6) {
                continue;
            }
            if (_internal_connectivity(current, timeout_ms) == 0 ) {
                result = 0;
                break;
            }
        }

        if (result != 0) {
            break;
        }
    } while (0);
    
    if (addr) {
        freeaddrinfo(addr);
    }

    return result;
}

int _internal_connectivity(const struct addrinfo *addr, int timeout_ms) {
    int cliSock = -1, arg, result = -1;
    do {
        if ((cliSock = socket(addr->ai_family, addr->ai_socktype, 0)) == -1) {
            printf("Socket Error: %d\n", errno);
            break;
        }
        printf("Client Socket %d created\n", cliSock);
        
        // Set non-blocking
        if ((arg = fcntl(cliSock, F_GETFL, NULL)) < 0) {
            fprintf(stderr, "Error fcntl(..., F_GETFL) (%s)\n", strerror(errno));
            break;
        }
        arg |= O_NONBLOCK;
        if (fcntl(cliSock, F_SETFL, arg) < 0) {
            fprintf(stderr, "Error fcntl(..., F_SETFL) (%s)\n", strerror(errno));
            break;
        }
        
        if (connect(cliSock, addr->ai_addr, addr->ai_addrlen) >= 0) {
            printf("Client Connection created successfully\n");
            result = 0;
            break;
        }
        
        if (errno == EINPROGRESS) {
            int success = 0;
            fprintf(stderr, "EINPROGRESS in connect() - selecting\n");
            do {
                int res;
                struct timeval tv;
                fd_set myset;
                tv.tv_sec = timeout_ms / 1000;
                tv.tv_usec = (timeout_ms % 1000) * 1000;
                FD_ZERO(&myset);
                FD_SET(cliSock, &myset);
                res = select(cliSock + 1, NULL, &myset, NULL, &tv);
                if (res < 0 && errno != EINTR) {
                    fprintf(stderr, "Error connecting %d - %s\n", errno, strerror(errno));
                    break;
                }
                else if (res > 0) {
                    int valopt = 0;
                    socklen_t lon = sizeof(int);
                    // Socket selected for write
                    if (getsockopt(cliSock, SOL_SOCKET, SO_ERROR, (void *)(&valopt), &lon) < 0) {
                        fprintf(stderr, "Error in getsockopt() %d - %s\n", errno, strerror(errno));
                        break;
                    }
                    // Check the value returned...
                    if (valopt) {
                        fprintf(stderr, "Error in delayed connection() %d - %s\n", valopt, strerror(valopt));
                        break;
                    }
                    success = 1;
                    break;
                }
                else {
                    fprintf(stderr, "Timeout in select() - Cancelling!\n");
                    break;
                }
            } while (1);
            if (success == 0) {
                break;
            }
        } else {
            fprintf(stderr, "Error connecting %d - %s\n", errno, strerror(errno));
            break;
        }
        result = 0;
    } while(0);
    
    if (cliSock != -1) {
        close(cliSock);
        printf("Client Sockets closed\n");
    }
    
    return result;
}

int convertHostNameToIpString (const char *host, char *ipString, size_t len) {
    int result = -1;
    do {
        if (host==NULL || ipString==NULL || len<16) {
            break;
        }
        struct hostent *he;

        if ((he = gethostbyname(host)) == NULL) {
            printf("Couldn't get hostname\n");
            break;
        }

        char *ip = inet_ntoa( *((struct in_addr *)he->h_addr) );

        if (ip == NULL) {
            break;
        }
        strncpy(ipString, ip, len);
        result = 0;
    } while (0);
    return result;
}
