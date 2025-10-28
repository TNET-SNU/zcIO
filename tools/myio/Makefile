CC := gcc
CFLAGS := -Wall -Wextra -O2
LDFLAGS := -laio

TARGET := io
SRC := io_test.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET)

