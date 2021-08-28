module app;

import vecs;

import bindbc.glfw.bindstatic;
import bindbc.glfw.types;
import bindbc.opengl;
import dlib.geometry;
import dlib.math;

import std.experimental.logger : errorf, trace, tracef;
import std.string : format, fromStringz, toStringz;
import std.typecons : Tuple, tuple;


static immutable vertexShader = q{
#version 330 core

layout(location = 0) in vec3 pos;
uniform mat4 view, proj, model;

out vec3 pos_color;

void main() {
	gl_Position =  proj * view * model * vec4(pos.xyz, 1.0f);
	pos_color = vec3(clamp(pos.x, 0.1, 1), clamp(pos.y, 0.1, 1), clamp(pos.z, 0.1, 1));
}};


static immutable fragmentShader = q{
#version 330 core

in vec3 pos_color;
out vec4 Color;

void main() {
    Color = vec4(pos_color, 1.0f);
}};

// super simplistic input manager
bool[int] keys;


  // ==============
 // # Components #
// ==============

enum Input;
enum Graphics;

struct Transform
{
	vec3 position;
	vec3 size;
	vec3 rotation;
}

struct Model
{
	vec3 position;
	vec3 scale;
	vec3 rotation;
}

struct Camera
{
	vec3 position;
	Tuple!(float, "fov", float, "aspectRatio", float, "near", float, "far") frustum;
	mat4 projection;
	mat4 view;
}

struct Shader
{
	uint vao;
	uint vbo;
	uint ibo;
	uint program;
}


  // ===========
 // # Systems #
// ===========

void cameraSystem(World.Query!Camera query)
{
	import std.functional : memoize;
	alias perpective = memoize!(perspectiveMatrix!float);
	alias lookAt = memoize!(lookAtMatrix!float);

	auto camera = query.get!Camera(query.front);

	with (camera.frustum) camera.projection = perpective(fov, aspectRatio, near, far);
	camera.view = lookAt(camera.position, camera.position + vec3(0, 0, -1), vec3(0, 1, 0));
}

void inputSystem(World.Query!Model.With!Input query)
{
	import std.algorithm : std_each = each;
	import std.range : takeOne;

	query.each!((_, ref model) {
		if (keys[GLFW_KEY_W]) model.rotation.x -= 0.03;
		if (keys[GLFW_KEY_A]) model.rotation.y += 0.03;
		if (keys[GLFW_KEY_S]) model.rotation.x += 0.03;
		if (keys[GLFW_KEY_D]) model.rotation.y -= 0.03;
	});

	if (keys[GLFW_KEY_ESC]) glfwGetCurrentContext.glfwSetWindowShouldClose(true);
}

void renderCubeSystem(World.Query!(Transform, Model, Graphics) queryCube, World.Query!Camera queryCamera, ref Shader shader)
{
	with(shader) queryCube.each!((ref transform, ref model, ref graphics)
	{
		  // ===================
		 // # Cube's vertices #
		// ===================

		const halflen = vec3(transform.size.x / 2, transform.size.y / 2, transform.size.z / 2);
		float[3 * 4 * 2] quadVBuffer;
		with (transform) quadVBuffer = [
			// front face
			position.x - halflen.x, position.y + halflen.y, position.z + halflen.z, // top    left
			position.x + halflen.x, position.y + halflen.y, position.z + halflen.z, // top    right
			position.x - halflen.x, position.y - halflen.y, position.z + halflen.z, // bottom left
			position.x + halflen.x, position.y - halflen.y, position.z + halflen.z, // bottom right

			// back face
			position.x - halflen.x, position.y + halflen.y, position.z - halflen.z, // top    left
			position.x + halflen.x, position.y + halflen.y, position.z - halflen.z, // top    right
			position.x - halflen.x, position.y - halflen.y, position.z - halflen.z, // bottom left
			position.x + halflen.x, position.y - halflen.y, position.z - halflen.z, // bottom right
		];


		  // ==================
		 // # Cube's indices #
		// ==================

		uint[6 * 6] quadIBuffer = [
			0, 1, 3, 3, 2, 0, // front
			5, 4, 6, 6, 7, 5, // back
			4, 0, 2, 2, 6, 4, // left
			1, 5, 7, 7, 3, 1, // right
			4, 5, 1, 1, 0, 4, // top
			2, 3, 7, 7, 6, 2, // bottom
		];


		  // ==========================
		 // # Calculate Cube's Model #
		// ==========================

		mat4 objectModel;
		with (model) objectModel = translationMatrix(transform.position)
			* scaleMatrix(scale)
			* rotationMatrix(Axis.x, -rotation.x)
			* rotationMatrix(Axis.y,  rotation.y)
			* rotationMatrix(Axis.z,  rotation.z)
			* translationMatrix(-transform.position)
			* translationMatrix(position);

		const camera = queryCamera.get!Camera(queryCamera.front);


		  // =============================
		 // # Send Color & Model to GPU #
		// =============================

		with (camera) glUniformMatrix4fv(glGetUniformLocation(program, "proj"), 1, false, projection.arrayof.ptr);
		with (camera) glUniformMatrix4fv(glGetUniformLocation(program, "view"), 1, false, view.arrayof.ptr);
		glUniformMatrix4fv(glGetUniformLocation(program, "model"), 1, false, objectModel.arrayof.ptr);


		  // ======================
		 // # Update buffer info #
		// ======================

		glBindVertexArray(vao);

		glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, quadVBuffer.sizeof, quadVBuffer.ptr, GL_DYNAMIC_DRAW);

		glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
		glBufferData(GL_ELEMENT_ARRAY_BUFFER, quadIBuffer.sizeof, quadIBuffer.ptr, GL_DYNAMIC_DRAW);

		glVertexAttribPointer(0, 3, GL_FLOAT, false, 3*float.sizeof, null);
		glEnableVertexAttribArray(0);


		  // ========
		 // # Draw #
		// ========

		glBindVertexArray(vao);
		glDrawElements(GL_TRIANGLES, quadIBuffer.length, GL_UNSIGNED_INT, null);
		glBindVertexArray(0);
	});
}


alias World = EntityManagerT!(void delegate() @safe nothrow);

void main()
{
	if (!glfwInit()) assert(false, "Failed to initialize GLFW");
	version(VECS_EXAMPLE_LOGGING) trace("[GLFW] successfully initialized.");

	glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
	glfwWindowHint(GLFW_OPENGL_DEBUG_CONTEXT, GLFW_TRUE);
	glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
	glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);

	auto monitor = glfwGetPrimaryMonitor();
	auto videomode = glfwGetVideoMode(monitor);
	auto window = glfwCreateWindow(videomode.width, videomode.height, "[VECS] OpenGL Square Example", monitor, null);

	window.glfwMakeContextCurrent();
	version(VECS_EXAMPLE_LOGGING) trace("[GLFW] window context created.");

	auto lib = loadOpenGL();
	version(VECS_EXAMPLE_LOGGING) tracef("[OpenGL] loaded version: %s.", lib);


	uint program = glCreateProgram();

	{
		auto vshader = glCreateShader(GL_VERTEX_SHADER);
		auto fshader = glCreateShader(GL_FRAGMENT_SHADER);
		scope(exit) glDeleteShader(vshader);
		scope(exit) glDeleteShader(fshader);

		glShaderSource(vshader, 1, [vertexShader.toStringz].ptr, null);
		glShaderSource(fshader, 1, [fragmentShader.toStringz].ptr, null);

		glCompileShader(vshader);
		vshader.errorShaderProgram!true;
		version(VECS_EXAMPLE_LOGGING) trace("[Shader] vertex compiled successfully.");

		glCompileShader(fshader);
		fshader.errorShaderProgram!true;
		version(VECS_EXAMPLE_LOGGING) trace("[Shader] fragment compiled successfully.");

		glAttachShader(program, vshader);
		glAttachShader(program, fshader);

		glLinkProgram(program);
		program.errorShaderProgram!false;
		version(VECS_EXAMPLE_LOGGING) trace("[Program] linked successfully.");
	}


	  // ================
	 // # Quad Buffers #
	// ================

	version(VECS_EXAMPLE_LOGGING) trace("[OpenGL] preparing buffers.");
	uint vao, vbo, ibo;
	glGenVertexArrays(1, &vao);
	glGenBuffers(1, &vbo);
	glGenBuffers(1, &ibo);


	  // =========================
	 // # Set up GLFW callbacks #
	// =========================

	version(VECS_EXAMPLE_LOGGING) trace("[GLFW] setting up callbacks.");
	window.glfwSetMouseButtonCallback(&mouseButtonCallback);
	window.glfwSetWindowSizeCallback(&windowSizeCallback);
	window.glfwSetKeyCallback(&keyCallback);


	auto world = new World();
	version(VECS_EXAMPLE_LOGGING) trace("[VECS] initialized.");

	window.glfwSetWindowUserPointer(cast(void*)world);


	  // ======================
	 // # Lets define a Cube #
	// ======================

	version(VECS_EXAMPLE_LOGGING) trace("[VECS] creating default entities.");
	auto cube = world.entity
		.emplace!Transform(vec3(0, 0, 0), vec3(1, 1, 1), vec3(0, 0, 0))
		.emplace!Model(vec3(0, 0, 0), vec3(1, 1, 1), vec3(0, 0, 0))
		.add!Graphics
		.add!Input;


	  // =====================
	 // # Perpective Camera #
	// =====================

	world.entity.emplace!Camera(
		vec3(0, 0, 3),
		tuple!("fov", "aspectRatio", "near", "far")(45f, cast(float)videomode.width/cast(float)videomode.height, .1f, 100f)
	);


	  // =================================================
	 // # Keep track of shader program inside callbacks #
	// =================================================

	version(VECS_EXAMPLE_LOGGING) trace("[VECS] preparing default resources.");
	world.addResource!Shader(Shader(vao, vbo, ibo, program));


	  // ===============================
	 // # Input Manager default state #
	// ===============================

	version(VECS_EXAMPLE_LOGGING) trace("[Input] preparing input manager.");
	keys = [
		GLFW_KEY_A: false,
		GLFW_KEY_D: false,
		GLFW_KEY_S: false,
		GLFW_KEY_W: false,

		GLFW_KEY_ESC: false,
	];


	  // ===================
	 // # OpenGL settings #
	// ===================

	version(VECS_EXAMPLE_LOGGING) trace("[OpenGL] defining environment settings.");
	glfwSwapInterval(1);
	glClearColor(.02f, .02f, .02f, 1f);
	glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);


	  // =============
	 // # Main loop #
	// =============

	version(VECS_EXAMPLE_LOGGING) trace("[Example] entering the main loop.");
	while (!glfwWindowShouldClose(window))
	{
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

		glUseProgram(program);

		with (world)
		{
			cameraSystem(query!Camera);
			inputSystem(query!(Select!Model, With!Input));
			renderCubeSystem(query!(Transform, Model, Graphics), query!Camera, resource!Shader);
		}

		glfwSwapBuffers(window);
		glfwPollEvents();
	}

	version(VECS_EXAMPLE_LOGGING) trace("[Example] terminating program.");
	window.glfwDestroyWindow();
	glfwTerminate();
}


extern (C) void errorCalback(int errorCode, const char* message)
{
	errorf("[GLFW] error code [%s]: %s", errorCode, message.fromStringz);
}

void errorShaderProgram(bool shader)(uint id)
{
	int success;

	static if (shader)
		glGetShaderiv(id, GL_COMPILE_STATUS, &success);
	else
		glGetProgramiv(id, GL_LINK_STATUS, &success);

	if (!success)
	{
		int len;
		static if (shader)
			glGetShaderiv(id, GL_INFO_LOG_LENGTH, &len);
		else
			glGetProgramiv(id, GL_INFO_LOG_LENGTH, &len);

		char[] buf = new char[len];

		static if (shader)
		{
			glGetShaderInfoLog(id, len, null, buf.ptr);

			int shader;
			glGetShaderiv(id, GL_SHADER_TYPE, &shader);
			immutable string type = shader == GL_VERTEX_SHADER ? "VertexShader" : "FragmentShader";
		}
		else
		{
			glGetProgramInfoLog(id, len, null, buf.ptr);
			static immutable string type = "Program";
		}

		assert(false, "[%s] failed to compile: %s".format(type, buf));
	}
}


extern(C) nothrow:
void mouseButtonCallback(GLFWwindow* window, int button, int action, int mods)
{
	if (action == GLFW_PRESS)
	{
		import std.exception : assumeWontThrow;

		World world = cast(World) window.glfwGetWindowUserPointer();

		double mouseX, mouseY;
		window.glfwGetCursorPos(&mouseX, &mouseY);

		int frameX, frameY;
		window.glfwGetFramebufferSize(&frameX, &frameY);


		  // ==============================================
		 // # Normalize cursor position between -1 and 1 #
		// ==============================================

		mouseX =  2f * mouseX / frameX - 1f;
		mouseY = -(2f * mouseY / frameY - 1f);


		  // ===========================================================
		 // # Raycast from 2D to 3D and intersect with the near plane #
		// ===========================================================

		auto screenToWorld = (vec2 mouse) {
			Camera* camera = world.query!Camera.each.front[1]; // only one camera
			vec4 clip = vec4(mouseX, mouseY, -1f, 1f);

			with (camera)
			{
				// dlib doesn't allow Matrix * Vector, so we need to transpose
				vec4 eye;
				with (clip * projection.inverse.transposed) eye = vec4(x, y, -1f, 0f);
				vec3 ray = (eye * view.inverse.transposed).xyz.normalized;

				// for some reason these are nothrow
				Plane plane;
				plane.fromPointAndNormal(vec3(0, 0, 0), vec3(0, 0, 1f)).assumeWontThrow;
				plane.intersectsLineSegment(position, position + ray.normalized, ray).assumeWontThrow;

				return ray;
			}
		};


		if (mods & GLFW_MOD_CONTROL && button == GLFW_MOUSE_BUTTON_LEFT)
		{
			// spawn a cube with pivot at '0, 0, 0' translated to 'x, y, z'
			Entity entity;
			with (screenToWorld(vec2(mouseX, mouseY))) entity = world.entity
					.emplace!Transform(vec3(0, 0, 0), vec3(1, 1, 1), vec3(0, 0, 0))
					.emplace!Model(vec3(x, y, z), vec3(1, 1, 1), vec3(0, 0, 0))
					.add!Graphics
					.add!Input;
			version(VECS_EXAMPLE_LOGGING) tracef("[VECS] entity '%d' created", entity).assumeWontThrow;
		}
		else if (button == GLFW_MOUSE_BUTTON_LEFT)
		{
			// spawn a cube with pivot at 'x, y, z'
			Entity entity;
			with (screenToWorld(vec2(mouseX, mouseY))) entity = world.entity
					.emplace!Transform(vec3(x, y, z), vec3(1, 1, 1), vec3(0, 0, 0))
					.emplace!Model(vec3(0, 0, 0), vec3(1, 1, 1), vec3(0, 0, 0))
					.add!Graphics
					.add!Input;
			version(VECS_EXAMPLE_LOGGING) tracef("[VECS] entity '%d' created", entity).assumeWontThrow;
		}
		else if (button == GLFW_MOUSE_BUTTON_RIGHT)
		{
			// destroy the most recent spawned cube
			foreach_reverse(entity; world.query!Transform)
			{
				world.destroyEntity(entity);
				version(VECS_EXAMPLE_LOGGING) tracef("[VECS] entity '%d' destroyed", entity).assumeWontThrow;
				break;
			}
		}
	}
}

void keyCallback(GLFWwindow* window, int key, int, int action, int)
{
	switch (action)
	{
		case (GLFW_PRESS):   keys[key] = true;  break;
		case (GLFW_RELEASE): keys[key] = false; break;
		default:
	}
}

void windowSizeCallback(GLFWwindow*, int width, int height)
{
	glViewport(0, 0, width, height);
}
