# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered!

describe BuildsController do
  include GitRepoTestHelper

  let(:tmp_dir) { Dir.mktmpdir }
  let(:project_repo_url) { repo_temp_dir }
  let(:project) { projects(:test).tap { |p| p.repository_url = project_repo_url } }
  let(:default_build) do
    project.builds.create!(label: 'master branch', git_ref: 'master', git_sha: 'a' * 40, creator: user)
  end

  before do
    create_repo_with_an_additional_branch('test_branch')
  end

  def stub_git_reference_check(returns: false)
    GitRepository.any_instance.stubs(:commit_from_ref).returns(returns)
  end

  as_a_viewer do
    unauthorized :get, :new, project_id: :foo
    unauthorized :post, :create, project_id: :foo
    unauthorized :get, :edit, id: 1, project_id: :foo
    unauthorized :put, :update, id: 1, project_id: :foo
    unauthorized :post, :build_docker_image, id: 1, project_id: :foo

    describe '#index' do
      it 'works without builds' do
        get :index, params: {project_id: project.to_param}
        assert_response :ok
      end

      it 'displays basic build info' do
        project.builds.create!(creator: user, label: 'test branch', git_ref: 'test_branch', git_sha: 'a' * 40)
        project.builds.create!(creator: user, label: 'master branch', git_ref: 'master', git_sha: 'b' * 40)
        get :index, params: {project_id: project.to_param}
        assert_response :ok
        @response.body.must_include 'test branch'
        @response.body.must_include 'master branch'
      end

      it 'can search' do
        build = builds(:docker_build)
        get :index, params: {project_id: project.to_param, search: {git_sha: build.git_sha}}
        assigns(:builds).must_equal [build]
      end
    end

    describe '#show' do
      before { default_build }

      it 'displays information about the build' do
        get :show, params: {project_id: project.to_param, id: default_build.id}
        assert_response :ok
        @response.body.must_include default_build.label
      end

      it 'displays the output of docker builds' do
        default_build.create_docker_job
        default_build.save!

        get :show, params: {project_id: project.to_param, id: default_build.id}
        assert_response :ok
        @response.body.must_include 'Docker Build Output'
      end
    end
  end

  as_a_project_deployer do
    describe '#new' do
      it 'renders' do
        get :new, params: {project_id: project.to_param}
        assert_response :ok
      end

      it "does not render when disabled" do
        project.update_column :docker_image_building_disabled, true
        get :new, params: {project_id: project.to_param}
        assert_redirected_to project_builds_path(project)
        assert flash[:alert]
      end
    end

    describe "#create" do
      def self.it_renders_error
        describe "with error" do
          let(:git_sha) { false }

          it "renders error" do
            create
            assert_response :unprocessable_entity
          end
        end
      end

      def create
        post(
          :create,
          params: {
            project_id: project.to_param,
            build: { label: 'Test creation', git_ref: 'master', description: 'hi there' },
            format: format
          }
        )
      end

      let(:git_sha) { '0123456789012345678901234567890123456789' }

      before do
        stub_git_reference_check(returns: git_sha)
      end

      describe 'html' do
        let(:format) { 'html' }

        it 'can create a build' do
          create
          assert_response :redirect

          new_build = Build.last
          assert_equal('Test creation', new_build.label)
          assert_equal(git_sha, new_build.git_sha)
          assert_redirected_to project_build_path(project, new_build)
        end

        it 'can create a build with same git_ref as previous' do
          create
          post(
            :create,
            params: {
              project_id: project.to_param,
              build: { label: 'Test creation 2', git_ref: 'master', description: 'hi there' }
            }
          )
          Build.last.label.must_equal 'Test creation 2'
        end

        it 'starts the build' do
          DockerBuilderService.any_instance.expects(:run)
          create
        end

        it "does not start the build when there were errors" do
          DockerBuilderService.any_instance.expects(:run).never
          stub_git_reference_check(returns: false)
          create
        end

        it "does not create when disabled" do
          project.update_column :docker_image_building_disabled, true
          create
          assert_redirected_to project_builds_path(project)
          assert flash[:alert]
        end

        it_renders_error
      end

      describe 'json' do
        let(:format) { 'json' }

        it 'can create a build' do
          create
          assert_response :created
          response.body.must_equal "{}"
        end

        it_renders_error
      end
    end

    describe '#edit' do
      before { default_build }

      it 'renders' do
        get :edit, params: {project_id: project.to_param, id: default_build.id}
        assert_response :ok
        @response.body.must_include default_build.label
      end
    end

    describe "#update" do
      def update(params = {label: 'New updated label!'})
        put :update, params: {project_id: project.to_param, id: default_build.id, build: params, format: format}
      end

      before { default_build }

      describe "html" do
        let(:format) { 'html' }

        it 'updates the build' do
          update
          assert_response :redirect
          default_build.reload.label.must_equal 'New updated label!'
        end

        it "renders when it fails to update" do
          Build.any_instance.expects(:update_attributes).returns false
          update
          assert_template :edit
          assert_response :unprocessable_entity
        end

        it 'prevents changing the git ref' do
          assert_raises ActionController::UnpermittedParameters do
            update git_ref: 'test_branch'
          end
        end

        it 'prevents changing the git sha' do
          assert_raises ActionController::UnpermittedParameters do
            update git_sha: '0123456789012345678901234567890123456789'
          end
        end
      end

      describe "json" do
        let(:format) { 'json' }

        it 'updates the build' do
          update
          assert_response :success
          response.body.must_equal "{}"
          default_build.reload.label.must_equal 'New updated label!'
        end

        it "renders when it fails to update" do
          Build.any_instance.expects(:update_attributes).returns false
          update
          assert_response :unprocessable_entity
          response.body.must_equal "{}"
        end
      end
    end

    describe "#build_docker_image" do
      def build
        post :build_docker_image, params: {project_id: project.to_param, id: default_build.id, format: format}
      end

      before { DockerBuilderService.any_instance.expects(:run) }

      describe 'html' do
        let(:format) { 'html' }

        it "builds an image" do
          build
          assert_redirected_to [project, default_build]
        end

        it "does not build when disabled" do
          DockerBuilderService.any_instance.unstub(:run)
          DockerBuilderService.any_instance.expects(:run).never
          project.update_column :docker_image_building_disabled, true
          build
          assert_redirected_to project_builds_path(project)
          assert flash[:alert]
        end
      end

      describe 'json' do
        let(:format) { 'json' }

        it "builds an image" do
          build
          assert_response :success
        end
      end
    end
  end
end
