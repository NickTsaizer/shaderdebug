#include <epoxy/gl.h>
#include <EGL/egl.h>
#include <png.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *kVertexShaderSource =
    "#version 450 core\n"
    "layout(location = 0) out vec2 input_uv_0;\n"
    "vec2 positions[3] = vec2[](\n"
    "    vec2(-1.0, -1.0),\n"
    "    vec2( 3.0, -1.0),\n"
    "    vec2(-1.0,  3.0)\n"
    ");\n"
    "void main()\n"
    "{\n"
    "    vec2 pos = positions[gl_VertexID];\n"
    "    gl_Position = vec4(pos, 0.0, 1.0);\n"
    "    input_uv_0 = pos * 0.5 + 0.5;\n"
    "}\n";

typedef struct Options {
    const char *fragment_path;
    const char *output_path;
    int size;
} Options;

static char *read_text_file(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "failed to open %s\n", path);
        return NULL;
    }

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }

    long size = ftell(file);
    if (size < 0) {
        fclose(file);
        return NULL;
    }
    rewind(file);

    char *buffer = (char *)malloc((size_t)size + 1);
    if (!buffer) {
        fclose(file);
        return NULL;
    }

    size_t read_size = fread(buffer, 1, (size_t)size, file);
    fclose(file);
    if (read_size != (size_t)size) {
        free(buffer);
        return NULL;
    }

    buffer[size] = '\0';
    return buffer;
}

static bool write_png(const char *path, int width, int height, const uint8_t *rgba)
{
    FILE *file = fopen(path, "wb");
    if (!file) {
        fprintf(stderr, "failed to open output %s\n", path);
        return false;
    }

    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png) {
        fclose(file);
        return false;
    }

    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_write_struct(&png, NULL);
        fclose(file);
        return false;
    }

    if (setjmp(png_jmpbuf(png))) {
        png_destroy_write_struct(&png, &info);
        fclose(file);
        return false;
    }

    png_init_io(png, file);
    png_set_IHDR(
        png,
        info,
        (png_uint_32)width,
        (png_uint_32)height,
        8,
        PNG_COLOR_TYPE_RGBA,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT);

    png_write_info(png, info);

    png_bytep *rows = (png_bytep *)malloc(sizeof(png_bytep) * (size_t)height);
    if (!rows) {
        png_destroy_write_struct(&png, &info);
        fclose(file);
        return false;
    }

    for (int y = 0; y < height; ++y) {
        rows[y] = (png_bytep)(rgba + ((size_t)(height - 1 - y) * (size_t)width * 4u));
    }

    png_write_image(png, rows);
    png_write_end(png, NULL);

    free(rows);
    png_destroy_write_struct(&png, &info);
    fclose(file);
    return true;
}

static void print_shader_log(GLuint shader, const char *label)
{
    GLint log_length = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &log_length);
    if (log_length <= 1) {
        return;
    }

    char *log = (char *)malloc((size_t)log_length + 1u);
    if (!log) {
        return;
    }

    GLsizei written = 0;
    glGetShaderInfoLog(shader, log_length, &written, log);
    log[written] = '\0';
    fprintf(stderr, "%s shader log:\n%s\n", label, log);
    free(log);
}

static void print_program_log(GLuint program)
{
    GLint log_length = 0;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &log_length);
    if (log_length <= 1) {
        return;
    }

    char *log = (char *)malloc((size_t)log_length + 1u);
    if (!log) {
        return;
    }

    GLsizei written = 0;
    glGetProgramInfoLog(program, log_length, &written, log);
    log[written] = '\0';
    fprintf(stderr, "program log:\n%s\n", log);
    free(log);
}

static GLuint compile_shader(GLenum type, const char *source, const char *label)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);

    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        print_shader_log(shader, label);
        glDeleteShader(shader);
        return 0;
    }

    return shader;
}

static GLuint build_program(const char *fragment_source)
{
    GLuint vertex_shader = compile_shader(GL_VERTEX_SHADER, kVertexShaderSource, "vertex");
    if (!vertex_shader) {
        return 0;
    }

    GLuint fragment_shader = compile_shader(GL_FRAGMENT_SHADER, fragment_source, "fragment");
    if (!fragment_shader) {
        glDeleteShader(vertex_shader);
        return 0;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, vertex_shader);
    glAttachShader(program, fragment_shader);
    glLinkProgram(program);

    glDeleteShader(vertex_shader);
    glDeleteShader(fragment_shader);

    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        print_program_log(program);
        glDeleteProgram(program);
        return 0;
    }

    return program;
}

static bool parse_args(int argc, char **argv, Options *options)
{
    options->fragment_path = NULL;
    options->output_path = NULL;
    options->size = 512;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--fragment") == 0 && i + 1 < argc) {
            options->fragment_path = argv[++i];
        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            options->output_path = argv[++i];
        } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            options->size = atoi(argv[++i]);
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return false;
        }
    }

    return options->fragment_path && options->output_path && options->size > 0;
}

int main(int argc, char **argv)
{
    Options options;
    if (!parse_args(argc, argv, &options)) {
        fprintf(stderr, "usage: shaderdebug_renderer --fragment file.glsl --output out.png [--size 512]\n");
        return 1;
    }

    char *fragment_source = read_text_file(options.fragment_path);
    if (!fragment_source) {
        return 1;
    }

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        fprintf(stderr, "eglGetDisplay failed\n");
        free(fragment_source);
        return 1;
    }

    if (!eglInitialize(display, NULL, NULL)) {
        fprintf(stderr, "eglInitialize failed\n");
        free(fragment_source);
        return 1;
    }

    if (!eglBindAPI(EGL_OPENGL_API)) {
        fprintf(stderr, "eglBindAPI failed\n");
        eglTerminate(display);
        free(fragment_source);
        return 1;
    }

    const EGLint config_attribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };

    EGLConfig egl_config = NULL;
    EGLint num_configs = 0;
    if (!eglChooseConfig(display, config_attribs, &egl_config, 1, &num_configs) || num_configs == 0) {
        fprintf(stderr, "eglChooseConfig failed\n");
        eglTerminate(display);
        free(fragment_source);
        return 1;
    }

    const EGLint pbuffer_attribs[] = {
        EGL_WIDTH, options.size,
        EGL_HEIGHT, options.size,
        EGL_NONE,
    };

    EGLSurface surface = eglCreatePbufferSurface(display, egl_config, pbuffer_attribs);
    if (surface == EGL_NO_SURFACE) {
        fprintf(stderr, "eglCreatePbufferSurface failed\n");
        eglTerminate(display);
        free(fragment_source);
        return 1;
    }

    const EGLint context_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 4,
        EGL_CONTEXT_MINOR_VERSION, 5,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE,
    };

    EGLContext context = eglCreateContext(display, egl_config, EGL_NO_CONTEXT, context_attribs);
    if (context == EGL_NO_CONTEXT) {
        fprintf(stderr, "eglCreateContext failed\n");
        eglDestroySurface(display, surface);
        eglTerminate(display);
        free(fragment_source);
        return 1;
    }

    if (!eglMakeCurrent(display, surface, surface, context)) {
        fprintf(stderr, "eglMakeCurrent failed\n");
        eglDestroyContext(display, context);
        eglDestroySurface(display, surface);
        eglTerminate(display);
        free(fragment_source);
        return 1;
    }

    GLuint program = build_program(fragment_source);
    free(fragment_source);
    if (!program) {
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(display, context);
        eglDestroySurface(display, surface);
        eglTerminate(display);
        return 1;
    }

    GLuint texture = 0;
    GLuint framebuffer = 0;
    GLuint vao = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, options.size, options.size, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);

    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "framebuffer incomplete\n");
        glDeleteFramebuffers(1, &framebuffer);
        glDeleteTextures(1, &texture);
        glDeleteProgram(program);
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(display, context);
        eglDestroySurface(display, surface);
        eglTerminate(display);
        return 1;
    }

    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);

    glViewport(0, 0, options.size, options.size);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(program);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();

    size_t pixel_count = (size_t)options.size * (size_t)options.size * 4u;
    uint8_t *pixels = (uint8_t *)malloc(pixel_count);
    if (!pixels) {
        fprintf(stderr, "failed to allocate pixel buffer\n");
        glDeleteVertexArrays(1, &vao);
        glDeleteFramebuffers(1, &framebuffer);
        glDeleteTextures(1, &texture);
        glDeleteProgram(program);
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(display, context);
        eglDestroySurface(display, surface);
        eglTerminate(display);
        return 1;
    }

    glReadPixels(0, 0, options.size, options.size, GL_RGBA, GL_UNSIGNED_BYTE, pixels);

    bool write_ok = write_png(options.output_path, options.size, options.size, pixels);
    free(pixels);

    glDeleteVertexArrays(1, &vao);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
    glDeleteProgram(program);

    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);

    if (!write_ok) {
        fprintf(stderr, "failed to write png\n");
        return 1;
    }

    return 0;
}
